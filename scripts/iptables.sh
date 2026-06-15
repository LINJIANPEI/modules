#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf
# ======================== 全局缓存变量 ========================
CACHED_IPV6=""
CACHED_TUN_ENABLE=""
CACHED_TUN_AUTO_ROUTE=""
CACHED_TUN_DEVICE=""
CACHED_REDIR_PORT=""
CACHED_TPROXY_PORT=""
CACHED_DNS_PORT=""
CACHED_ENABLE=""
CACHED_ENHANCED_MODE=""
CACHED_TUN_MODE=""
CACHED_APP_UIDS=""            # 缓存应用 UID 列表（空格分隔）

# ======================== 辅助函数 ========================

# 注意：log 函数由外部提供，保持原格式，此处不再定义

# 从 packages.list 获取单个包名的 UID
get_uid_for_package() {
    local pkg="$1"
    local pkg_list_file="/data/system/packages.list"   # ✅ 系统包名->UID 映射文件
    [ ! -f "$pkg_list_file" ] && return 1
    awk -v pkg="$pkg" '$1 == pkg {print $2; exit}' "$pkg_list_file"
}

# 从包名列表文件读取包名，转换为 UID 列表（空格分隔）
refresh_app_uids() {
    local pkg_list_file="$PACKAGES_LIST_FILE"
    local uid_list=""
    
    if [ ! -f "$pkg_list_file" ]; then
        log Warn "包名列表文件不存在: $pkg_list_file" "${log_dir}/iptables.log"
        apps=""
        CACHED_APP_UIDS=""
        return 0
    fi
    
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | xargs)
        [ -z "$line" ] && continue
        [ "${line#\#}" != "$line" ] && continue
        
        local uid_val=$(get_uid_for_package "$line")
        if [ -n "$uid_val" ]; then
            uid_list="$uid_list $uid_val"
        else
            log Warn "包名 $line 未找到对应 UID，已跳过" "${log_dir}/iptables.log"
        fi
    done < "$pkg_list_file"
    
    apps=$(echo "$uid_list" | xargs)
    CACHED_APP_UIDS="$apps"
    log Info "从包名文件加载了应用 UID" "${log_dir}/iptables.log"
}

# 从 YAML 读取配置（总是重新读取）
_cache_yaml_values() {
    CACHED_IPV6=$(yamlcli -f "${YAML_FILE}" get 'ipv6' 2>/dev/null)
    CACHED_TUN_ENABLE=$(yamlcli -f "${YAML_FILE}" get 'tun.enable' 2>/dev/null)
    CACHED_TUN_AUTO_ROUTE=$(yamlcli -f "${YAML_FILE}" get 'tun.auto-route' 2>/dev/null)
    CACHED_TUN_DEVICE=$(yamlcli -f "${YAML_FILE}" get 'tun.device' 2>/dev/null)
    CACHED_REDIR_PORT=$(yamlcli -f "${YAML_FILE}" get 'redir-port' 2>/dev/null)
    CACHED_TPROXY_PORT=$(yamlcli -f "${YAML_FILE}" get 'tproxy-port' 2>/dev/null)
    CACHED_ENABLE=$(yamlcli -f "${YAML_FILE}" get 'dns.enable' 2>/dev/null)    
    CACHED_ENHANCED_MODE=$(yamlcli -f "${YAML_FILE}" get 'dns.enhanced-mode' 2>/dev/null)
    
    
    # 直接获取 dns.listen 值
    local dns_listen_raw=$(yamlcli -f "${YAML_FILE}" get 'dns.listen' 2>/dev/null | head -1)
    
    
    if [ "$CACHED_ENABLE" = "true" ]; then
    # 方法1：使用 sed 提取端口号（支持 0.0.0.0:1053, [::]:1053, :1053 等格式）
        CACHED_DNS_PORT=$(echo "$dns_listen_raw" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')
    else
        CACHED_DNS_PORT=${redir_port}
    
    fi
    # 如果上面的方法失败，尝试直接提取数字
    if [ -z "$CACHED_DNS_PORT" ]; then
        CACHED_DNS_PORT=$(echo "$dns_listen_raw" | grep -oE '[0-9]+$')
    fi
    
    # 如果还是失败，尝试从冒号后提取所有数字
    if [ -z "$CACHED_DNS_PORT" ]; then
        CACHED_DNS_PORT=$(echo "$dns_listen_raw" | awk -F':' '{print $NF}' | grep -oE '[0-9]+')
    fi
    
    # 最终验证
    if [ -z "$CACHED_DNS_PORT" ] || ! echo "$CACHED_DNS_PORT" | grep -qE '^[0-9]+$'; then
        log Warn "DNS 端口解析失败，原始值: '$dns_listen_raw'，使用默认 1053" "${log_dir}/iptables.log"
        CACHED_DNS_PORT="1053"
    else
        log Info "DNS 端口解析成功: $CACHED_DNS_PORT" "${log_dir}/iptables.log"
    fi
}

# 增强版 iptables_wait（保持原逻辑，仅依赖 CACHED_IPV6）
iptables_wait() {
    local is_ipv4=false is_ipv6=false has_ip_pattern=false arg
    for arg in "$@"; do
        case "$arg" in
            *.*.*.*) is_ipv4=true; has_ip_pattern=true ;;
            *:*:*)   is_ipv6=true; has_ip_pattern=true ;;
        esac
    done
    if [ "$has_ip_pattern" = "false" ]; then
        is_ipv4=true
        [ "$CACHED_IPV6" = "true" ] && is_ipv6=true
    fi
    [ "$is_ipv4" = "true" ] && iptables -w 100 "$@"
    [ "$is_ipv6" = "true" ] && [ "$CACHED_IPV6" = "true" ] && ip6tables -w 100 "$@"
}

# 检查 TProxy 内核支持（使用实际规则测试）
_check_tproxy_support() {
    iptables -t mangle -N TEST_TPROXY 2>/dev/null
    if iptables -t mangle -A TEST_TPROXY -j TPROXY 2>/dev/null; then
        iptables -t mangle -D TEST_TPROXY -j TPROXY 2>/dev/null
        iptables -t mangle -X TEST_TPROXY 2>/dev/null
        echo "true"
    else
        iptables -t mangle -X TEST_TPROXY 2>/dev/null
        echo "false"
    fi
}

# 保留 IP 地址常量
readonly RESERVED_IPV4="0.0.0.0/8 10.0.0.0/8 100.0.0.0/8 127.0.0.0/8 169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"
readonly RESERVED_IPV6="::/128 ::1/128 ::ffff:0:0/96 100::/64 64:ff9b::/96 2001::/32 2001:10::/28 2001:20::/28 2001:db8::/32 2002::/16 fe80::/10 ff00::/8"

_skip_reserved_ips() {
    local table=$1 chain=$2
    for ip in $RESERVED_IPV4; do
        iptables_wait -t "$table" -A "$chain" -d "$ip" -j RETURN 2>/dev/null
    done
    if [ "$CACHED_IPV6" = "true" ]; then
        for ip in $RESERVED_IPV6; do
            iptables_wait -t "$table" -A "$chain" -d "$ip" -j RETURN 2>/dev/null
        done
    fi
}

_apply_app_filter() {
    local table=$1 chain=$2 target=$3 target_args=$4 proto=$5
    local effective_mode="${mode}"
    [ "$CACHED_ENHANCED_MODE" = "fake-ip" ] && effective_mode="blacklist"
    if [ "${effective_mode}" = "global" ]; then
        effective_mode="blacklist"
        apps=""
    fi

    if [ "${effective_mode}" = "blacklist" ]; then
        for appuid in ${apps}; do
            [ -n "${appuid}" ] && iptables_wait -t "$table" -A "$chain" -p "$proto" -m owner --uid-owner "${appuid}" -j RETURN
        done
        iptables_wait -t "$table" -A "$chain" -p "$proto" -j "$target" $target_args
    elif [ "${effective_mode}" = "whitelist" ]; then
        for appuid in ${apps}; do
            [ -n "${appuid}" ] && iptables_wait -t "$table" -A "$chain" -p "$proto" -m owner --uid-owner "${appuid}" -j "$target" $target_args
        done
        iptables_wait -t "$table" -A "$chain" -p "$proto" -m owner --uid-owner 0 -j "$target" $target_args
        iptables_wait -t "$table" -A "$chain" -p "$proto" -m owner --uid-owner 1052 -j "$target" $target_args
        iptables_wait -t "$table" -A "$chain" -p "$proto" -j RETURN
    fi
}

_block_loopback_to_proxy() {
    local port=$1
    iptables_wait -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${port}" -j REJECT 2>/dev/null
    [ "$CACHED_IPV6" = "true" ] && iptables_wait -A OUTPUT -d ::1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${port}" -j REJECT 2>/dev/null
}

# ======================== Tun 模式 ========================
_setup_tun_auto() {
    iptables_wait -D FORWARD -o "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null
    iptables_wait -I FORWARD -o "$CACHED_TUN_DEVICE" -j ACCEPT
    iptables_wait -D FORWARD -i "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null
    iptables_wait -I FORWARD -i "$CACHED_TUN_DEVICE" -j ACCEPT
    log Info "auto-route 已开启，核心自动处理路由" "${log_dir}/iptables.log"
}

_setup_tun_manual() {
    ip -4 rule add fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
    ip -4 route add default dev "$CACHED_TUN_DEVICE" table "${table_id}" 2>/dev/null
    if [ "$CACHED_IPV6" = "true" ]; then
        ip -6 rule add fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
        ip -6 route add default dev "$CACHED_TUN_DEVICE" table "${table_id}" 2>/dev/null
    fi

    iptables_wait -A FORWARD -o "$CACHED_TUN_DEVICE" -j ACCEPT
    iptables_wait -A FORWARD -i "$CACHED_TUN_DEVICE" -j ACCEPT

    iptables_wait -t mangle -N KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -F KERNEL_OUT
    iptables_wait -t mangle -A KERNEL_OUT -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    _apply_app_filter "mangle" "KERNEL_OUT" "MARK" "--set-xmark ${mark_id}" "tcp"
    _apply_app_filter "mangle" "KERNEL_OUT" "MARK" "--set-xmark ${mark_id}" "udp"
    iptables_wait -t mangle -A OUTPUT -j KERNEL_OUT

    if [ "$CACHED_IPV6" != "true" ]; then
        echo 1 > /proc/sys/net/ipv6/conf/"$CACHED_TUN_DEVICE"/disable_ipv6 2>/dev/null
    fi
    log Info "Tun 手动模式规则应用成功" "${log_dir}/iptables.log"
}

_cleanup_tun_auto() {
    iptables_wait -D FORWARD -o "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null
    iptables_wait -D FORWARD -i "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null
    log Info "auto-route 已关闭，核心停止自动路由" "${log_dir}/iptables.log"
}

_cleanup_tun_manual() {
    ip -4 rule del fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
    ip -4 route del default dev "$CACHED_TUN_DEVICE" table "${table_id}" 2>/dev/null
    if [ "$CACHED_IPV6" = "true" ]; then
        ip -6 rule del fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
        ip -6 route del default dev "$CACHED_TUN_DEVICE" table "${table_id}" 2>/dev/null
    fi

    iptables_wait -D FORWARD -o "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null
    iptables_wait -D FORWARD -i "$CACHED_TUN_DEVICE" -j ACCEPT 2>/dev/null

    iptables_wait -t mangle -D OUTPUT -j KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -F KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -X KERNEL_OUT 2>/dev/null
    log Info "Tun 手动模式规则移除成功" "${log_dir}/iptables.log"
}

# ======================== Redirect 模式 ========================
_setup_redirect() {
    iptables_wait -t nat -N KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -F KERNEL_PRE
    iptables_wait -t nat -A KERNEL_PRE -p udp --dport 53 -j REDIRECT --to-ports "${CACHED_DNS_PORT}"
    _skip_reserved_ips "nat" "KERNEL_PRE"
    iptables_wait -t nat -A KERNEL_PRE -p tcp -i lo -j REDIRECT --to-ports "${CACHED_REDIR_PORT}"
    iptables_wait -t nat -A KERNEL_PRE -p tcp -i lo -j RETURN
    iptables_wait -t nat -A KERNEL_PRE -p tcp -j REDIRECT --to-ports "${CACHED_REDIR_PORT}"
    iptables_wait -t nat -A PREROUTING -j KERNEL_PRE

    iptables_wait -t nat -N KERNEL_OUT 2>/dev/null
    iptables_wait -t nat -F KERNEL_OUT
    iptables_wait -t nat -A KERNEL_OUT -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    iptables_wait -t nat -A KERNEL_OUT -p udp --dport 53 -j REDIRECT --to-ports "${CACHED_DNS_PORT}"
    _skip_reserved_ips "nat" "KERNEL_OUT"
    _apply_app_filter "nat" "KERNEL_OUT" "REDIRECT" "--to-ports ${CACHED_REDIR_PORT}" "tcp"
    iptables_wait -t nat -A OUTPUT -j KERNEL_OUT

    _block_loopback_to_proxy "${CACHED_REDIR_PORT}"
    log Info "Redirect 规则应用成功" "${log_dir}/iptables.log"
}

_cleanup_redirect() {
    iptables_wait -t nat -D PREROUTING -j KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -D OUTPUT -j KERNEL_OUT 2>/dev/null
    iptables_wait -t nat -F KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -X KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -F KERNEL_OUT 2>/dev/null
    iptables_wait -t nat -X KERNEL_OUT 2>/dev/null
    iptables_wait -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${CACHED_REDIR_PORT}" -j REJECT 2>/dev/null
    [ "$CACHED_IPV6" = "true" ] && iptables_wait -D OUTPUT -d ::1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${CACHED_REDIR_PORT}" -j REJECT 2>/dev/null
    log Info "Redirect 规则移除成功" "${log_dir}/iptables.log"
}

# ======================== TProxy 模式 ========================
_setup_tproxy() {
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null
    ip rule add fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
    ip route add local default dev lo table "${table_id}" 2>/dev/null
    if [ "$CACHED_IPV6" = "true" ]; then
        sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null
        ip -6 rule add fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
        ip -6 route add local default dev lo table "${table_id}" 2>/dev/null
    fi

    # nat 表同时处理 UDP 和 TCP DNS
    iptables_wait -t nat -N DNS_KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -F DNS_KERNEL_PRE
    iptables_wait -t nat -A DNS_KERNEL_PRE -p udp --dport 53 -j REDIRECT --to-ports "${CACHED_DNS_PORT}"
    iptables_wait -t nat -A DNS_KERNEL_PRE -p tcp --dport 53 -j REDIRECT --to-ports "${CACHED_DNS_PORT}"
    iptables_wait -t nat -I PREROUTING -j DNS_KERNEL_PRE

    iptables_wait -t mangle -N KERNEL_PRE 2>/dev/null
    iptables_wait -t mangle -F KERNEL_PRE
    # mangle 表中跳过 DNS（让 nat 表处理），避免双重处理
    iptables_wait -t mangle -A KERNEL_PRE -p tcp --dport 53 -j RETURN
    iptables_wait -t mangle -A KERNEL_PRE -p udp --dport 53 -j RETURN
    iptables_wait -t mangle -A KERNEL_PRE -p tcp -m socket --transparent -j MARK --set-xmark "${mark_id}"
    iptables_wait -t mangle -A KERNEL_PRE -p udp -m socket --transparent -j MARK --set-xmark "${mark_id}"
    _skip_reserved_ips "mangle" "KERNEL_PRE"
    iptables_wait -t mangle -A KERNEL_PRE -p tcp -i lo -j TPROXY --on-port "${CACHED_TPROXY_PORT}" --tproxy-mark "${mark_id}"
    iptables_wait -t mangle -A KERNEL_PRE -p udp -i lo -j TPROXY --on-port "${CACHED_TPROXY_PORT}" --tproxy-mark "${mark_id}"
    for iface in $(ip -4 link show | grep -E '^[0-9]+:' | awk -F ': ' '{print $2}' | grep -v lo); do
        iptables_wait -t mangle -A KERNEL_PRE -p tcp -i "$iface" -j TPROXY --on-port "${CACHED_TPROXY_PORT}" --tproxy-mark "${mark_id}"
        iptables_wait -t mangle -A KERNEL_PRE -p udp -i "$iface" -j TPROXY --on-port "${CACHED_TPROXY_PORT}" --tproxy-mark "${mark_id}"
        log Info "已对接口 ${iface} 开启 TProxy 劫持" "${log_dir}/iptables.log"
    done
    iptables_wait -t mangle -A PREROUTING -j KERNEL_PRE

    iptables_wait -t mangle -N KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -F KERNEL_OUT
    iptables_wait -t mangle -A KERNEL_OUT -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    iptables_wait -t mangle -A KERNEL_OUT -p tcp --dport 53 -j RETURN
    iptables_wait -t mangle -A KERNEL_OUT -p udp --dport 53 -j RETURN
    _skip_reserved_ips "mangle" "KERNEL_OUT"
    _apply_app_filter "mangle" "KERNEL_OUT" "MARK" "--set-xmark ${mark_id}" "tcp"
    _apply_app_filter "mangle" "KERNEL_OUT" "MARK" "--set-xmark ${mark_id}" "udp"
    iptables_wait -t mangle -A OUTPUT -j KERNEL_OUT

    _block_loopback_to_proxy "${CACHED_TPROXY_PORT}"
    log Info "TProxy 规则应用成功（TCP/UDP DNS 均已转发）" "${log_dir}/iptables.log"
}

_cleanup_tproxy() {
    ip -4 rule del fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
    ip -4 route del local default dev lo table "${table_id}" 2>/dev/null
    if [ "$CACHED_IPV6" = "true" ]; then
        ip -6 rule del fwmark "${mark_id}" table "${table_id}" pref "${table_id}" 2>/dev/null
        ip -6 route del local default dev lo table "${table_id}" 2>/dev/null
    fi

    iptables_wait -t nat -D PREROUTING -j DNS_KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -F DNS_KERNEL_PRE 2>/dev/null
    iptables_wait -t nat -X DNS_KERNEL_PRE 2>/dev/null

    iptables_wait -t mangle -D PREROUTING -j KERNEL_PRE 2>/dev/null
    iptables_wait -t mangle -F KERNEL_PRE 2>/dev/null
    iptables_wait -t mangle -X KERNEL_PRE 2>/dev/null
    iptables_wait -t mangle -D OUTPUT -j KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -F KERNEL_OUT 2>/dev/null
    iptables_wait -t mangle -X KERNEL_OUT 2>/dev/null

    iptables_wait -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${CACHED_TPROXY_PORT}" -j REJECT 2>/dev/null
    [ "$CACHED_IPV6" = "true" ] && iptables_wait -D OUTPUT -d ::1 -p tcp -m owner --uid-owner "${uid}" -m tcp --dport "${CACHED_TPROXY_PORT}" -j REJECT 2>/dev/null
    log Info "TProxy 规则移除成功" "${log_dir}/iptables.log"
}

# ======================== 统一路由启停 ========================
_start_routing() {
    refresh_app_uids
    _cache_yaml_values
    _stop_routing 2>/dev/null

    if [ "${CACHED_TUN_ENABLE}" = "true" ]; then
        log Info "当前为 Tun 模式" "${log_dir}/iptables.log"
        if [ "${CACHED_TUN_AUTO_ROUTE}" = "true" ]; then
            _setup_tun_auto
        else
            _setup_tun_manual
        fi
        return 0
    fi

    local support_tproxy="$(_check_tproxy_support)"
    if [ "${support_tproxy}" != "true" ]; then
        log Warn "内核不支持 TProxy，切换至 Redirect 模式" "${log_dir}/iptables.log"
        _setup_redirect
    else
        _setup_tproxy
    fi
}

_stop_routing() {
    _cache_yaml_values
    
    if [ "${CACHED_TUN_ENABLE}" = "true" ]; then
        log Info "当前为 Tun 模式" "${log_dir}/iptables.log"
        if [ "${CACHED_TUN_AUTO_ROUTE}" = "true" ]; then
            _cleanup_tun_auto
        else
            _cleanup_tun_manual
        fi
        return 0
    fi

    local support_tproxy="$(_check_tproxy_support)"
    if [ "${support_tproxy}" != "true" ]; then
        _cleanup_redirect
    else
        _cleanup_tproxy
    fi
}










#

iptables_w="iptables -w 64"
ip6tables_w="ip6tables -w 64"

check_ipv6_nat_support() {
  if ! $ip6tables_w -t nat -L >/dev/null 2>&1; then
    log Warn "IPv6 NAT: 不支持" ${log_dir}/iptables.log
    return 1
  fi

  local redirect_ok=false
  if $ip6tables_w -t nat -A PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
    redirect_ok=true
    $ip6tables_w -t nat -D PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1
  fi

  if $redirect_ok; then
    log Info "IPv6 NAT: 支持（REDIRECT）" ${log_dir}/iptables.log
    return 0
  else
    log Warn "IPv6 NAT: 不支持" ${log_dir}/iptables.log
    return 1
  fi
}

enable_iptables() {
  if $iptables_w -t nat -L ADGUARD_REDIRECT_DNS >/dev/null 2>&1; then
    log Info "ADGUARD_REDIRECT_DNS 链已经存在" ${log_dir}/iptables.log
    if ! $iptables_w -t nat -C OUTPUT -j ADGUARD_REDIRECT_DNS >/dev/null 2>&1; then
      $iptables_w -t nat -I OUTPUT -j ADGUARD_REDIRECT_DNS
    fi
    return 0
  fi

  log Info "创建 ADGUARD_REDIRECT_DNS 链并添加规则" ${log_dir}/iptables.log
  $iptables_w -t nat -N ADGUARD_REDIRECT_DNS || return 1
  $iptables_w -t nat -A ADGUARD_REDIRECT_DNS -m owner --uid-owner $uid --gid-owner $gid -j RETURN || return 1

  for subnet in $ignore_dest_list; do
    if ! $iptables_w -t nat -A ADGUARD_REDIRECT_DNS -d $subnet -j RETURN >/dev/null 2>&1; then
      log Warn "警告：无法为 $subnet 添加绕过规则（可能由于 DNS 解析失败）" ${log_dir}/iptables.log
    fi
  done

  for subnet in $ignore_src_list; do
    if ! $iptables_w -t nat -A ADGUARD_REDIRECT_DNS -s $subnet -j RETURN >/dev/null 2>&1; then
      log Warn "警告：无法为源 $subnet 添加绕过规则" ${log_dir}/iptables.log
    fi
  done

  $iptables_w -t nat -A ADGUARD_REDIRECT_DNS -p udp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $iptables_w -t nat -A ADGUARD_REDIRECT_DNS -p tcp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $iptables_w -t nat -I OUTPUT -j ADGUARD_REDIRECT_DNS || return 1

  log Info "成功应用 iptables 规则" ${log_dir}/iptables.log
}

disable_iptables() {
  log Info "删除 ADGUARD_REDIRECT_DNS 链及规则" ${log_dir}/iptables.log
  $iptables_w -t nat -D OUTPUT -j ADGUARD_REDIRECT_DNS >/dev/null 2>&1
  $iptables_w -t nat -F ADGUARD_REDIRECT_DNS >/dev/null 2>&1
  $iptables_w -t nat -X ADGUARD_REDIRECT_DNS >/dev/null 2>&1
  return 0
}

add_block_ipv6_dns() {
  if $ip6tables_w -t filter -L ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
    log Info "ADGUARD_BLOCK_DNS 链已经存在" ${log_dir}/iptables.log
    if ! $ip6tables_w -t filter -C OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1; then
      $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS
    fi
    return 0
  fi

  log Info "创建 ADGUARD_BLOCK_DNS 链并添加规则" ${log_dir}/iptables.log
  $ip6tables_w -t filter -N ADGUARD_BLOCK_DNS || return 1
  $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p udp --dport 53 -j DROP || return 1
  $ip6tables_w -t filter -A ADGUARD_BLOCK_DNS -p tcp --dport 53 -j DROP || return 1
  $ip6tables_w -t filter -I OUTPUT -j ADGUARD_BLOCK_DNS || return 1

  log Info "成功应用 ipv6 iptables 规则" ${log_dir}/iptables.log
}

del_block_ipv6_dns() {
  log Info "删除 ADGUARD_BLOCK_DNS 链及规则"  ${log_dir}/iptables.log
  $ip6tables_w -t filter -D OUTPUT -j ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -F ADGUARD_BLOCK_DNS >/dev/null 2>&1
  $ip6tables_w -t filter -X ADGUARD_BLOCK_DNS >/dev/null 2>&1
  return 0
}

enable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    log Warn "IPv6 NAT 不支持，跳过 IPv6 DNS 劫持" ${log_dir}/iptables.log
    return 0
  fi

  if $ip6tables_w -t nat -L ADGUARD_REDIRECT_DNS6 >/dev/null 2>&1; then
    log Info "ADGUARD_REDIRECT_DNS6 链已经存在" ${log_dir}/iptables.log
    if ! $ip6tables_w -t nat -C OUTPUT -j ADGUARD_REDIRECT_DNS6 >/dev/null 2>&1; then
      $ip6tables_w -t nat -I OUTPUT -j ADGUARD_REDIRECT_DNS6
    fi
    return 0
  fi

  log Info "创建 ADGUARD_REDIRECT_DNS6 链并添加规则" ${log_dir}/iptables.log
  $ip6tables_w -t nat -N ADGUARD_REDIRECT_DNS6 || return 1
  $ip6tables_w -t nat -A ADGUARD_REDIRECT_DNS6 -m owner --uid-owner $uid --gid-owner $gid -j RETURN || return 1

  for subnet in $ignore_dest_list; do
    if ! $ip6tables_w -t nat -A ADGUARD_REDIRECT_DNS6 -d $subnet -j RETURN >/dev/null 2>&1; then
      log Warn "警告：无法为 $subnet 添加 ipv6 绕过规则" ${log_dir}/iptables.log
    fi
  done

  for subnet in $ignore_src_list; do
    if ! $ip6tables_w -t nat -A ADGUARD_REDIRECT_DNS6 -s $subnet -j RETURN >/dev/null 2>&1; then
      log Warn "警告：无法为源 $subnet 添加 ipv6 绕过规则" ${log_dir}/iptables.log
    fi
  done

  $ip6tables_w -t nat -A ADGUARD_REDIRECT_DNS6 -p udp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $ip6tables_w -t nat -A ADGUARD_REDIRECT_DNS6 -p tcp --dport 53 -j REDIRECT --to-ports $redir_port || return 1
  $ip6tables_w -t nat -I OUTPUT -j ADGUARD_REDIRECT_DNS6 || return 1

  log Info "成功应用 ipv6 iptables 规则" ${log_dir}/iptables.log
}

disable_ipv6_iptables() {
  if ! check_ipv6_nat_support; then
    log Info "IPv6 NAT 不支持，跳过 IPv6 DNS 劫持清理" ${log_dir}/iptables.log
    return 0
  fi

  log Info "删除 ADGUARD_REDIRECT_DNS6 链及规则" ${log_dir}/iptables.log
  $ip6tables_w -t nat -D OUTPUT -j ADGUARD_REDIRECT_DNS6 >/dev/null 2>&1
  $ip6tables_w -t nat -F ADGUARD_REDIRECT_DNS6 >/dev/null 2>&1
  $ip6tables_w -t nat -X ADGUARD_REDIRECT_DNS6 >/dev/null 2>&1
  return 0
}


case "$1" in
    enable)
        if [ "${enable_mihomo}" = "true" ]; then
            disable_iptables || exit 1
            del_block_ipv6_dns || exit 1
            disable_ipv6_iptables || exit 1
            _start_routing
        else
            _stop_routing
            enable_iptables || exit 1
            if [ "$block_ipv6_dns" = true ]; then
               log Info "IPv6 DNS 模式: block (丢弃 IPv6 DNS 流量)" ${log_dir}/iptables.log
               add_block_ipv6_dns || exit 1
            else
               log Info "IPv6 DNS 模式: hijack (劫持 IPv6 到 AdGuard Home)" ${log_dir}/iptables.log                  enable_ipv6_iptables || exit 1
            fi
        fi
        ;;
    disable)
        _stop_routing
        disable_iptables || exit 1
        del_block_ipv6_dns || exit 1
        disable_ipv6_iptables || exit 1
        ;;
    switch_to_mihomo)
        disable_iptables || exit 1
        del_block_ipv6_dns || exit 1
        disable_ipv6_iptables || exit 1
        _start_routing
        ;;
    switch_to_adguard)
        _stop_routing
        enable_iptables || exit 1
         if [ "$block_ipv6_dns" = true ]; then
            log Info "IPv6 DNS 模式: block (丢弃 IPv6 DNS 流量)" ${log_dir}/iptables.log
            add_block_ipv6_dns || exit 1
         else
            log Info "IPv6 DNS 模式: hijack (劫持 IPv6 到 AdGuard Home)" ${log_dir}/iptables.log                          enable_ipv6_iptables || exit 1
         fi
        ;;
    *)
        echo "用法: $0 {enable|disable|switch_to_mihomo|switch_to_adguard}"
        exit 1
        ;;
esac