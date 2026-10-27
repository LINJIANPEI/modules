#!/system/bin/sh
# ============================================================================
# /data/adb/modules/Linlin/scripts/dns.sh
#
# DNS 劫持 + DoT/DoQ/DoH3 封锁（不常驻，无 SNI）+ 规则守护
#
# 用法:
#   sh dns.sh {enable|disable|status} [DNS_PORT]
#       enable  → 部署 + 后台启动守护
#       disable → 停守护 + 清规则
#       status  → 查看状态
#   sh dns.sh daemon      # 前台运行守护（供 init service 或调试）
#
# 状态管理（零新增文件）：
#   守护端口、IPv6 栈禁用来源，以 dns_state_* 变量写入 fun.conf。
#   - 脚本状态与用户配置变量名隔离，不覆盖 redir_port / block_ipv6_dns 等
#   - 写入用 sed -i 原子替换 + 末尾换行检测，不产生重复行、不拼接最后一行
#   - 模块更新覆盖 fun.conf 时：
#       端口丢失 → 回落 redir_port，需重新 enable 指定
#       栈状态丢失 → 保守恢复为启用(0)，不锁死网络
#
# 守护：
#   每 daemon_interval 秒校验核心规则 -C + 链内规则数量（可发现"部分丢失"
#   和"重复追加"），异常调 rebuild_all。rebuild_all 幂等、带 -C 校验、
#   带 IPv6 栈自愈，绝不切飞行模式。连续失败退避 15→30→45→60s 封顶。
#   单实例靠 pgrep（fallback /proc 遍历），零新文件。
#
# IPv6 DNS 53：
#   block_ipv6_dns=true  → 首选 filter DROP，失败回退 nat REDIRECT，都失败禁栈
#   block_ipv6_dns=false → 首选 nat REDIRECT，失败回退 filter DROP，都失败禁栈
#   ip6tables 不存在     → 禁栈
#
# 853(tcp/udp) + udp443：首选 filter DROP，失败降级 REJECT，都失败按配置决定是否禁栈
# ============================================================================

source /data/adb/modules/Linlin/fun.conf
mkdir -p "${log_dir}" 2>/dev/null

LOG_FILE="${log_dir}/dns.log"
CONF_FILE="/data/adb/modules/Linlin/fun.conf"
exec 2>>"$LOG_FILE" 2>/dev/null || true

# ---------- 变量兜底 ----------
: "${uid:=root}"
: "${gid:=net_raw}"
: "${redir_port:=5591}"
: "${block_ipv6_dns:=false}"
: "${ipv6_block_fail_disable_stack:=false}"
: "${daemon_interval:=15}"
: "${dns_state_port:=}"
: "${dns_state_ipv6_blocked:=}"
: "${DNS_PORT_ENV:=}"

# ============================================================================
# fun.conf 状态读写
# ============================================================================
conf_set() {
    _k="$1"; _v="$2"
    [ -f "$CONF_FILE" ] || return 1

    # 末尾无换行则补一个，避免 >> 与最后一行拼接
    [ -n "$(tail -c 1 "$CONF_FILE" 2>/dev/null)" ] && echo "" >> "$CONF_FILE"

    sed -i "/^${_k}=/d" "$CONF_FILE" 2>/dev/null
    printf '%s=%s\n' "$_k" "$_v" >> "$CONF_FILE"
    return 0
}

conf_unset() {
    _k="$1"
    [ -f "$CONF_FILE" ] || return 1
    grep -q "^${_k}=" "$CONF_FILE" 2>/dev/null || return 0
    sed -i "/^${_k}=/d" "$CONF_FILE" 2>/dev/null
    return 0
}

# ---------- DNS 端口 ----------
calc_dns_port() {
    _ov="$1"
    if [ -n "$_ov" ]; then
        DNS_PORT="$_ov"
    elif [ "${enable_mihomo}" = "true" ] && [ "${MIHOMO_DNS_ENABLE}" = "true" ]; then
        DNS_PORT="${MIHOMO_DNS_PORT:-$redir_port}"
    else
        DNS_PORT="$redir_port"
    fi
}

if [ -n "$DNS_PORT_ENV" ]; then
    DNS_PORT="$DNS_PORT_ENV"
else
    calc_dns_port "$2"
fi

# ---------- 链名 ----------
CHAIN4="REDIRECT_DNS"
CHAIN6="REDIRECT_DNS6"
CHAIN_BLK6="BLOCK_DNS6"
CHAIN_BLK="BLOCK_ENC_DNS"

# ---------- IPv6 能力 ----------
IPV6_CMD_OK=false
IPV6_NAT_OK=false
IPV6_FILTER_OK=false
IPV6_MODE=""

# ============================================================================
# IPv6 网络栈禁用 / 恢复（状态存 fun.conf，幂等）
# ============================================================================
block_ipv6_stack() {
    _reason="${1:-未指定原因}"
    log Warn "${_reason} → 禁用 IPv6 网络栈兜底" "$LOG_FILE"

    # 首次记录禁用来源：1=脚本写入，0=用户本来就禁了（恢复时不碰）
    if [ -z "${dns_state_ipv6_blocked:-}" ]; then
        _cur_pre=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [ "$_cur_pre" = "1" ]; then
            conf_set dns_state_ipv6_blocked 0
            dns_state_ipv6_blocked=0
        else
            conf_set dns_state_ipv6_blocked 1
            dns_state_ipv6_blocked=1
        fi
    fi

    _ok=false
    if [ -w /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null && _ok=true
        echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
    fi
    if [ "$_ok" != "true" ] && command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 && _ok=true
        sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
    fi

    if [ "$_ok" = "true" ]; then
        _cur=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [ "$_cur" = "1" ]; then
            log Warn "IPv6 网络栈已禁用（disable_ipv6=1，校验通过）" "$LOG_FILE"
            log Warn "所有 IPv6 流量中断：DNS/DoT/DoQ/网页；可能影响 VoLTE/VoWiFi" "$LOG_FILE"
            log Warn "重启或 sh dns.sh disable 恢复" "$LOG_FILE"
        else
            log Warn "IPv6 网络栈写入后校验失败（当前=$_cur，期望=1）" "$LOG_FILE"
        fi
    else
        log Warn "禁用 IPv6 网络栈失败，IPv6 流量仍可能绕过 DNS 劫持" "$LOG_FILE"
    fi
}

unblock_ipv6_stack() {
    _cur=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)

    if [ "$_cur" != "1" ]; then
        [ -n "${dns_state_ipv6_blocked:-}" ] && conf_unset dns_state_ipv6_blocked
        dns_state_ipv6_blocked=""
        return 0
    fi

    case "${dns_state_ipv6_blocked:-}" in
        0)
            # 用户手动禁的栈，不碰
            return 0
            ;;
        1)
            : # 脚本禁的，恢复
            ;;
        *)
            log Warn "IPv6 栈状态未知（disable_ipv6=1），按恢复启用处理" "$LOG_FILE"
            ;;
    esac

    _ok=false
    if [ -w /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null && _ok=true
        echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
    fi
    if [ "$_ok" != "true" ] && command -v sysctl >/dev/null 2>&1; then
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 && _ok=true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1
    fi

    _cur2=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    if [ "$_cur2" = "0" ]; then
        log Info "IPv6 网络栈已恢复为启用(0)，校验通过" "$LOG_FILE"
        conf_unset dns_state_ipv6_blocked
        dns_state_ipv6_blocked=""
    else
        log Warn "IPv6 网络栈恢复失败（当前=$_cur2，期望=0），保留状态" "$LOG_FILE"
    fi
}

# ============================================================================
# IPv6 能力探测
# ============================================================================
detect_ipv6() {
    IPV6_CMD_OK=false
    IPV6_NAT_OK=false
    IPV6_FILTER_OK=false
    IPV6_MODE=""

    if ! command -v ip6tables >/dev/null 2>&1; then
        block_ipv6_stack "ip6tables 不可用，无法封 IPv6 DNS"
        return 1
    fi

    if ip6tables -w 2 -t filter -L >/dev/null 2>&1; then
        IPV6_FILTER_OK=true
    fi

    if ip6tables -w 2 -t nat -L >/dev/null 2>&1; then
        if ip6tables -w 2 -t nat -A PREROUTING -p tcp --dport 65534 \
                -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
            IPV6_NAT_OK=true
            ip6tables -w 2 -t nat -D PREROUTING -p tcp --dport 65534 \
                -j REDIRECT --to-port 65534 2>/dev/null
        fi
    fi

    if [ "$block_ipv6_dns" = "true" ]; then
        if [ "$IPV6_FILTER_OK" = "true" ]; then
            IPV6_MODE="drop"
            IPV6_CMD_OK=true
            log Info "block_ipv6_dns=true → 首选 filter DROP（栈保留）" "$LOG_FILE"
        elif [ "$IPV6_NAT_OK" = "true" ]; then
            IPV6_MODE="redirect"
            IPV6_CMD_OK=true
            log Warn "block_ipv6_dns=true 但 filter 不可用 → 降级 REDIRECT（栈保留）" "$LOG_FILE"
        else
            block_ipv6_stack "filter 与 nat 均不可用，无法封 IPv6 DNS"
            return 1
        fi
    else
        if [ "$IPV6_NAT_OK" = "true" ]; then
            IPV6_MODE="redirect"
            IPV6_CMD_OK=true
            log Info "block_ipv6_dns=false → 首选 nat REDIRECT（栈保留）" "$LOG_FILE"
        elif [ "$IPV6_FILTER_OK" = "true" ]; then
            IPV6_MODE="drop"
            IPV6_CMD_OK=true
            log Warn "block_ipv6_dns=false 但 nat 不可用 → 降级 filter DROP（栈保留）" "$LOG_FILE"
        else
            block_ipv6_stack "nat 与 filter 均不可用，无法处理 IPv6 DNS"
            return 1
        fi
    fi

    if [ "$IPV6_MODE" = "redirect" ] && [ "$block_ipv6_dns" = "true" ]; then
        if ! ss -lunp 2>/dev/null | grep -qE "(\[::\]|:::):${DNS_PORT}([[:space:]]|$)"; then
            log Warn "DNS_PORT=$DNS_PORT 未监听 IPv6，REDIRECT 后 DNS 将失败（不出网，不泄漏）" "$LOG_FILE"
        fi
    fi

    return 0
}

# ============================================================================
# DNS 53：IPv4 劫持
# ============================================================================
rebuild_dns4() {
    iptables -w 2 -t nat -N "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4"
    iptables -w 2 -t nat -C OUTPUT -j "$CHAIN4" 2>/dev/null || \
        iptables -w 2 -t nat -I OUTPUT 1 -j "$CHAIN4"

    iptables -w 2 -t nat -A "$CHAIN4" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    for s in ${ignore_dest_list}; do
        case "$s" in *:*) continue ;; esac
        iptables -w 2 -t nat -A "$CHAIN4" -d "$s" -j RETURN
    done
    for s in ${ignore_src_list}; do
        case "$s" in *:*) continue ;; esac
        iptables -w 2 -t nat -A "$CHAIN4" -s "$s" -j RETURN
    done

    iptables -w 2 -t nat -A "$CHAIN4" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    iptables -w 2 -t nat -A "$CHAIN4" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
}

# ============================================================================
# DNS 53：IPv6 REDIRECT
# ============================================================================
rebuild_dns6() {
    ip6tables -w 2 -t nat -N "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t nat -F "$CHAIN6"
    ip6tables -w 2 -t nat -C OUTPUT -j "$CHAIN6" 2>/dev/null || \
        ip6tables -w 2 -t nat -I OUTPUT 1 -j "$CHAIN6"

    ip6tables -w 2 -t nat -A "$CHAIN6" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    for s in ${ignore_dest_list}; do
        case "$s" in *:*) ip6tables -w 2 -t nat -A "$CHAIN6" -d "$s" -j RETURN ;; esac
    done
    for s in ${ignore_src_list}; do
        case "$s" in *:*) ip6tables -w 2 -t nat -A "$CHAIN6" -s "$s" -j RETURN ;; esac
    done

    ip6tables -w 2 -t nat -A "$CHAIN6" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    ip6tables -w 2 -t nat -A "$CHAIN6" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"

    ip6tables -w 2 -t nat -C OUTPUT -j "$CHAIN6" 2>/dev/null || return 1
    ip6tables -w 2 -t nat -C "$CHAIN6" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || return 1
    ip6tables -w 2 -t nat -C "$CHAIN6" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || return 1
    return 0
}

# ============================================================================
# DNS 53：IPv6 DROP
# ============================================================================
rebuild_dns6_block() {
    ip6tables -w 2 -t filter -N "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK6"
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK6" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK6"

    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" -p udp --dport 53 -j DROP
    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" -p tcp --dport 53 -j DROP

    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK6" 2>/dev/null || return 1
    ip6tables -w 2 -t filter -C "$CHAIN_BLK6" -p udp --dport 53 -j DROP 2>/dev/null || return 1
    ip6tables -w 2 -t filter -C "$CHAIN_BLK6" -p tcp --dport 53 -j DROP 2>/dev/null || return 1
    return 0
}

_clear_dns6() {
    ip6tables -w 2 -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t nat -F "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t nat -X "$CHAIN6" 2>/dev/null
}
_clear_dns6_blk() {
    ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -X "$CHAIN_BLK6" 2>/dev/null
}

apply_ipv6_dns() {
    case "$IPV6_MODE" in
        drop)
            if rebuild_dns6_block; then
                _clear_dns6
                log Info "IPv6 DNS 已 filter DROP（校验通过，栈保留）" "$LOG_FILE"
                return 0
            fi
            log Warn "filter DROP 建立或校验失败" "$LOG_FILE"
            if [ "$IPV6_NAT_OK" = "true" ]; then
                if rebuild_dns6; then
                    IPV6_MODE="redirect"
                    _clear_dns6_blk
                    log Warn "已回退到 nat REDIRECT（校验通过，栈保留）" "$LOG_FILE"
                    return 0
                fi
                log Warn "nat REDIRECT 回退也失败" "$LOG_FILE"
            else
                log Warn "nat 不可用，无法回退 REDIRECT" "$LOG_FILE"
            fi
            ;;
        redirect)
            if rebuild_dns6; then
                _clear_dns6_blk
                log Info "IPv6 DNS 已 nat REDIRECT（校验通过，栈保留）" "$LOG_FILE"
                return 0
            fi
            log Warn "nat REDIRECT 建立或校验失败" "$LOG_FILE"
            if [ "$IPV6_FILTER_OK" = "true" ]; then
                if rebuild_dns6_block; then
                    IPV6_MODE="drop"
                    _clear_dns6
                    log Warn "已回退到 filter DROP（校验通过，栈保留）" "$LOG_FILE"
                    return 0
                fi
                log Warn "filter DROP 回退也失败" "$LOG_FILE"
            else
                log Warn "filter 不可用，无法回退 DROP" "$LOG_FILE"
            fi
            ;;
        *)
            log Warn "IPV6_MODE 为空，跳过" "$LOG_FILE"
            ;;
    esac

    _clear_dns6
    _clear_dns6_blk
    block_ipv6_stack "IPv6 DNS 所有封锁通道均失败，禁用栈防止泄漏"
    IPV6_MODE=""
    return 1
}

# ============================================================================
# 853(tcp/udp) + udp443
# ============================================================================
rebuild_block4() {
    iptables -w 2 -t filter -N "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_BLK"
    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || \
        iptables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK"

    iptables -w 2 -t filter -A "$CHAIN_BLK" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    if iptables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && \
       iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null && \
       iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null; then
        _act="DROP"
    else
        iptables -w 2 -t filter -F "$CHAIN_BLK"
        iptables -w 2 -t filter -A "$CHAIN_BLK" \
            -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
        iptables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j REJECT
        iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 \
            -j REJECT --reject-with icmp-port-unreachable
        iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 \
            -j REJECT --reject-with icmp-port-unreachable
        _act="REJECT"
        log Warn "IPv4 DROP 不可用 → 853/udp443 降级 REJECT" "$LOG_FILE"
    fi

    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || return 1
    if [ "$_act" = "DROP" ]; then
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null || return 1
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null || return 1
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null || return 1
    else
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j REJECT 2>/dev/null || return 1
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 853 \
            -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || return 1
        iptables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 443 \
            -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || return 1
    fi
    BLOCK4_ACT="$_act"
    return 0
}

rebuild_block6() {
    ip6tables -w 2 -t filter -N "$CHAIN_BLK" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK"
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK"

    ip6tables -w 2 -t filter -A "$CHAIN_BLK" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    if ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && \
       ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null && \
       ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null; then
        _act="DROP"
    else
        ip6tables -w 2 -t filter -F "$CHAIN_BLK"
        ip6tables -w 2 -t filter -A "$CHAIN_BLK" \
            -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
        ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j REJECT
        ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 \
            -j REJECT --reject-with icmp6-port-unreachable
        ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 \
            -j REJECT --reject-with icmp6-port-unreachable
        _act="REJECT"
        log Warn "IPv6 DROP 不可用 → 853/udp443 降级 REJECT" "$LOG_FILE"
    fi

    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || return 1
    if [ "$_act" = "DROP" ]; then
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null || return 1
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null || return 1
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null || return 1
    else
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j REJECT 2>/dev/null || return 1
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 853 \
            -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || return 1
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p udp --dport 443 \
            -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null || return 1
    fi
    BLOCK6_ACT="$_act"
    return 0
}

# ============================================================================
# 全量重建（幂等，守护复用它，绝不切飞行模式）
# ============================================================================
rebuild_all() {
    log Info "重建规则 (DNS_PORT=$DNS_PORT, block_ipv6_dns=$block_ipv6_dns)" "$LOG_FILE"
    BLOCK4_ACT=""
    BLOCK6_ACT=""
    detect_ipv6

    if [ "$IPV6_CMD_OK" = "true" ]; then
        unblock_ipv6_stack
    fi

    rebuild_dns4

    if [ "$IPV6_CMD_OK" != "true" ]; then
        log Warn "IPv6 已禁用 → 跳过全部 IPv6 规则（DNS/DoT/DoQ/udp443）" "$LOG_FILE"
    else
        if apply_ipv6_dns; then
            if rebuild_block6; then
                log Info "IPv6 DNS 模式=$IPV6_MODE，853/udp443=$BLOCK6_ACT（校验通过）" "$LOG_FILE"
            else
                log Warn "IPv6 853/udp443 规则建立或校验失败，DoT/DoQ/DoH3 可经 IPv6 绕过" "$LOG_FILE"
                if [ "$ipv6_block_fail_disable_stack" = "true" ]; then
                    block_ipv6_stack "IPv6 853/udp443 封锁失败"
                    IPV6_CMD_OK=false
                    IPV6_MODE=""
                fi
            fi
        else
            _cur=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
            if [ "$_cur" != "1" ]; then
                log Warn "严重：IPv6 DNS 规则建立失败且栈禁用未生效，存在 DNS 泄漏风险" "$LOG_FILE"
            else
                log Warn "IPv6 DNS 规则建立失败 → 已禁用栈兜底" "$LOG_FILE"
            fi
            IPV6_CMD_OK=false
        fi
    fi

    if rebuild_block4; then
        log Info "IPv4 853/udp443=$BLOCK4_ACT（校验通过）" "$LOG_FILE"
    else
        log Warn "IPv4 853/udp443 规则建立或校验失败，DoT/DoQ/DoH3 可经 IPv4 绕过；IPv4 无兜底手段" "$LOG_FILE"
    fi
}

# ============================================================================
# 守护：规则检查（核心规则 -C + 链内规则数量双校验）
# ============================================================================
_count_ignore4() {
    _ci_n=0
    for _ci_s in ${ignore_dest_list} ${ignore_src_list}; do
        case "$_ci_s" in *:*) ;; *) _ci_n=$((_ci_n+1)) ;; esac
    done
    echo "$_ci_n"
}
_count_ignore6() {
    _ci_n=0
    for _ci_s in ${ignore_dest_list} ${ignore_src_list}; do
        case "$_ci_s" in *:*) _ci_n=$((_ci_n+1)) ;; esac
    done
    echo "$_ci_n"
}

check_rules() {
    _ok=true

    iptables -w 2 -t nat -C OUTPUT -j "$CHAIN4" 2>/dev/null || _ok=false
    iptables -w 2 -t nat -C "$CHAIN4" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || _ok=false
    iptables -w 2 -t nat -C "$CHAIN4" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || _ok=false
    _i4=$(_count_ignore4)
    _exp4=$((1 + _i4 + 2))
    _act4=$(iptables -w 2 -t nat -S "$CHAIN4" 2>/dev/null | grep -c '^-A')
    [ "$_act4" = "$_exp4" ] || _ok=false

    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || _ok=false
    _b4=0
    iptables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && _b4=1
    [ "$_b4" = "0" ] && iptables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j REJECT 2>/dev/null && _b4=1
    [ "$_b4" = "0" ] && _ok=false
    _actb4=$(iptables -w 2 -t filter -S "$CHAIN_BLK" 2>/dev/null | grep -c '^-A')
    [ "$_actb4" = "4" ] || _ok=false

    if [ "$IPV6_CMD_OK" = "true" ]; then
        _cur6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        [ "$_cur6" = "1" ] && _ok=false

        case "$IPV6_MODE" in
            redirect)
                ip6tables -w 2 -t nat -C OUTPUT -j "$CHAIN6" 2>/dev/null || _ok=false
                ip6tables -w 2 -t nat -C "$CHAIN6" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || _ok=false
                ip6tables -w 2 -t nat -C "$CHAIN6" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || _ok=false
                _i6=$(_count_ignore6)
                _exp6=$((1 + _i6 + 2))
                _act6=$(ip6tables -w 2 -t nat -S "$CHAIN6" 2>/dev/null | grep -c '^-A')
                [ "$_act6" = "$_exp6" ] || _ok=false
                ;;
            drop)
                ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK6" 2>/dev/null || _ok=false
                ip6tables -w 2 -t filter -C "$CHAIN_BLK6" -p udp --dport 53 -j DROP 2>/dev/null || _ok=false
                ip6tables -w 2 -t filter -C "$CHAIN_BLK6" -p tcp --dport 53 -j DROP 2>/dev/null || _ok=false
                _actb6d=$(ip6tables -w 2 -t filter -S "$CHAIN_BLK6" 2>/dev/null | grep -c '^-A')
                [ "$_actb6d" = "3" ] || _ok=false
                ;;
            *)
                _ok=false
                ;;
        esac

        ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || _ok=false
        _b6=0
        ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && _b6=1
        [ "$_b6" = "0" ] && ip6tables -w 2 -t filter -C "$CHAIN_BLK" -p tcp --dport 853 -j REJECT 2>/dev/null && _b6=1
        [ "$_b6" = "0" ] && _ok=false
        _actb6=$(ip6tables -w 2 -t filter -S "$CHAIN_BLK" 2>/dev/null | grep -c '^-A')
        [ "$_actb6" = "4" ] || _ok=false
    else
        _cur6=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [ "$_cur6" = "0" ] && command -v ip6tables >/dev/null 2>&1 && \
           ip6tables -w 2 -t filter -L >/dev/null 2>&1; then
            _ok=false
        fi
    fi

    [ "$_ok" = "true" ]
}

# ============================================================================
# 守护：单实例检测（零新文件，pgrep 优先，fallback /proc）
# ============================================================================
_find_daemon_pids() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "dns.sh daemon" 2>/dev/null
        return
    fi
    for _p in /proc/[0-9]*; do
        _pid="${_p#/proc/}"
        [ "$_pid" = "$$" ] && continue
        _cl=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null)
        case "$_cl" in
            *dns.sh*daemon*) echo "$_pid" ;;
        esac
    done
}

# ============================================================================
# 守护主循环
# ============================================================================
run_daemon() {
    for _p in $(_find_daemon_pids); do
        [ "$_p" = "$$" ] && continue
        log Warn "已有守护实例($_p)，退出" "$LOG_FILE"
        exit 0
    done

    detect_ipv6
    [ "$IPV6_CMD_OK" = "true" ] && unblock_ipv6_stack

    log Info "守护启动 (间隔=${daemon_interval}s, 端口=$DNS_PORT)" "$LOG_FILE"

    _fail=0
    _prev_blk6="$block_ipv6_dns"

    while true; do
        # 热重载配置
        if [ -f "$CONF_FILE" ]; then
            . "$CONF_FILE" 2>/dev/null
            : "${uid:=root}"; : "${gid:=net_raw}"; : "${redir_port:=5591}"
            : "${block_ipv6_dns:=false}"; : "${ipv6_block_fail_disable_stack:=false}"
            : "${daemon_interval:=15}"
            case "$daemon_interval" in
                ''|*[!0-9]*) daemon_interval=15 ;;
            esac
            [ "$daemon_interval" -lt 5 ] && daemon_interval=5
        fi

        # 端口优先级：dns_state_port > 环境变量 > fun.conf 默认
        if [ -n "${dns_state_port:-}" ]; then
            _want_port="$dns_state_port"
        elif [ -n "$DNS_PORT_ENV" ]; then
            _want_port="$DNS_PORT_ENV"
        else
            calc_dns_port ""
            _want_port="$DNS_PORT"
        fi

        # 变更汇总，一次 rebuild
        _need_rebuild=false
        if [ "$_want_port" != "$DNS_PORT" ]; then
            log Info "端口变更 ($DNS_PORT → $_want_port)，强制重建" "$LOG_FILE"
            DNS_PORT="$_want_port"
            _need_rebuild=true
        fi
        if [ "$block_ipv6_dns" != "$_prev_blk6" ]; then
            log Info "block_ipv6_dns 变更 ($_prev_blk6 → $block_ipv6_dns)，强制重建" "$LOG_FILE"
            _prev_blk6="$block_ipv6_dns"
            _need_rebuild=true
        fi
        if [ "$_need_rebuild" = "true" ]; then
            rebuild_all
            _fail=0
            sleep "$daemon_interval"
            continue
        fi

        if check_rules; then
            _fail=0
            sleep "$daemon_interval"
        else
            log Warn "检测到规则缺失/异常，开始重建" "$LOG_FILE"
            rebuild_all
            if check_rules; then
                _fail=0
                log Info "重建成功，规则恢复正常" "$LOG_FILE"
                sleep "$daemon_interval"
            else
                _fail=$((_fail + 1))
                _sleep=$((daemon_interval * _fail))
                [ "$_sleep" -gt 60 ] && _sleep=60
                log Warn "重建后仍异常（连续 $_fail 次），${_sleep}s 后重试" "$LOG_FILE"
                sleep "$_sleep"
            fi
        fi
    done
}

# ============================================================================
# 守护启动 / 停止
# ============================================================================
start_daemon() {
    _existing=$(_find_daemon_pids)
    if [ -n "$_existing" ]; then
        log Info "守护已在运行 (PID: $(echo $_existing))，跳过启动" "$LOG_FILE"
        return 0
    fi

    if command -v setsid >/dev/null 2>&1; then
        DNS_PORT_ENV="$DNS_PORT" setsid sh "$0" daemon >/dev/null 2>&1 &
    else
        export DNS_PORT_ENV="$DNS_PORT"
        ( sh "$0" daemon >/dev/null 2>&1 & )
    fi
    log Info "守护已后台启动（端口 $DNS_PORT，间隔 ${daemon_interval}s）" "$LOG_FILE"
}

stop_daemon() {
    _pids=$(_find_daemon_pids)
    [ -z "$_pids" ] && return 0
    kill $_pids 2>/dev/null
    sleep 1
    _pids=$(_find_daemon_pids)
    [ -n "$_pids" ] && kill -9 $_pids 2>/dev/null
    log Info "守护已停止" "$LOG_FILE"
}

# ============================================================================
# 部署
# ============================================================================
first_setup() {
    log Info "开始部署 (DNS_PORT=$DNS_PORT)" "$LOG_FILE"

    [ "$(settings get global private_dns_mode)" != "off" ] && \
        settings put global private_dns_mode off
    settings put global private_dns_specifier ""
    [ -d "/data/system/ifw" ] && rm -rf /data/system/ifw/*

    # 记录端口状态，供 daemon 跟随
    conf_set dns_state_port "$DNS_PORT"
    dns_state_port="$DNS_PORT"

    # 链已存在 → 只是重建规则，无需重载网络
    _need_reload=false
    iptables -w 2 -t nat -S "$CHAIN4" >/dev/null 2>&1 || _need_reload=true

    rebuild_all

    if [ "$_need_reload" = "true" ]; then
        for s in 1 0; do
            settings put global airplane_mode_on $s
            am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
        done
    else
        log Info "规则已存在，跳过飞行模式重载" "$LOG_FILE"
    fi

    log Info "部署完成" "$LOG_FILE"
}

# ============================================================================
# 清理
# ============================================================================
stop_all() {
    log Info "清理规则" "$LOG_FILE"

    unblock_ipv6_stack
    conf_unset dns_state_port
    dns_state_port=""

    iptables -w 2 -t nat -D OUTPUT -j "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -X "$CHAIN4" 2>/dev/null
    iptables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -X "$CHAIN_BLK" 2>/dev/null

    if command -v ip6tables >/dev/null 2>&1; then
        _clear_dns6
        _clear_dns6_blk
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_BLK" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_BLK" 2>/dev/null
        ip6tables -w 2 -t filter -D OUTPUT -j AGH_SNI 2>/dev/null
        ip6tables -w 2 -t filter -F AGH_SNI 2>/dev/null
        ip6tables -w 2 -t filter -X AGH_SNI 2>/dev/null
    else
        log Warn "ip6tables 不存在 → 跳过 IPv6 规则清理（栈已恢复）" "$LOG_FILE"
    fi

    iptables -w 2 -t filter -D OUTPUT -j AGH_SNI 2>/dev/null
    iptables -w 2 -t filter -F AGH_SNI 2>/dev/null
    iptables -w 2 -t filter -X AGH_SNI 2>/dev/null

    log Info "清理完成" "$LOG_FILE"
}

# ============================================================================
# status
# ============================================================================
show_status() {
    echo "=== 守护 ==="
    _dpids=$(_find_daemon_pids)
    if [ -n "$_dpids" ]; then
        echo "  状态           : 运行中 (PID: $(echo $_dpids))"
    else
        echo "  状态           : 未运行"
    fi
    echo "  检测间隔       : ${daemon_interval}s"
    echo

    echo "=== 状态存储（fun.conf） ==="
    echo "  dns_state_port : ${dns_state_port:-（未设置）}"
    echo "  ipv6_blocked   : ${dns_state_ipv6_blocked:-（未设置）}  (1=脚本禁, 0=用户禁)"
    echo

    echo "=== IPv6 能力 ==="
    if [ "$block_ipv6_dns" = "true" ]; then
        echo "  IPv6 策略      : true（首选 filter DROP，失败回退 nat REDIRECT）"
    else
        echo "  IPv6 策略      : false（首选 nat REDIRECT，失败回退 filter DROP）"
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        echo "  ip6tables      : 存在"
        ip6tables -w 2 -t filter -L >/dev/null 2>&1 \
            && echo "  filter 表      : 可用" \
            || echo "  filter 表      : 不可用"
        ip6tables -w 2 -t nat -L >/dev/null 2>&1 \
            && echo "  IPv6 nat       : 可用" \
            || echo "  IPv6 nat       : 不可用"
    else
        echo "  ip6tables      : 不存在"
    fi
    echo "  disable_ipv6   : $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
    echo "  block_ipv6_dns : ${block_ipv6_dns}"
    echo "  853/443 失败禁栈: ${ipv6_block_fail_disable_stack}"
    [ -n "$IPV6_MODE" ] && echo "  当前模式       : $IPV6_MODE"
    echo "  日志文件       : $LOG_FILE"
    echo

    echo "=== DNS IPv4 ==="
    iptables -t nat -S "$CHAIN4" 2>/dev/null || echo "  不存在"
    echo
    echo "=== DNS IPv6 ==="
    if command -v ip6tables >/dev/null 2>&1; then
        _f=0
        ip6tables -t nat -S "$CHAIN6" 2>/dev/null && { echo "  [REDIRECT]"; _f=1; }
        ip6tables -t filter -S "$CHAIN_BLK6" 2>/dev/null && { echo "  [DROP]"; _f=1; }
        [ "$_f" = "0" ] && echo "  不存在（保留原生解析）"
    else
        echo "  跳过（IPv6 栈已禁用）"
    fi
    echo

    echo "=== 853/udp443 IPv4 ==="
    iptables -S "$CHAIN_BLK" 2>/dev/null || echo "  不存在"
    echo
    echo "=== 853/udp443 IPv6 ==="
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t filter -S "$CHAIN_BLK" 2>/dev/null || echo "  不存在"
    else
        echo "  跳过（IPv6 栈已禁用）"
    fi
    echo

    echo "=== 计数器 ==="
    iptables -t nat -L "$CHAIN4" -n -v 2>/dev/null
    command -v ip6tables >/dev/null 2>&1 && {
        ip6tables -t nat -L "$CHAIN6" -n -v 2>/dev/null
        ip6tables -t filter -L "$CHAIN_BLK6" -n -v 2>/dev/null
    }
    echo

    echo "=== 端口监听 ==="
    ss -lunp 2>/dev/null | grep -E ":${DNS_PORT}(\s|$)" || echo "  ${DNS_PORT} 未监听"
}

# ============================================================================
# 入口
# ============================================================================
case "$1" in
    enable|"")
        first_setup
        start_daemon
        ;;
    disable)
        stop_daemon
        stop_all
        ;;
    daemon)
        run_daemon
        ;;
    status)
        show_status
        ;;
    *)
        echo "用法: $0 {enable|disable|status|daemon} [DNS_PORT]"
        exit 1
        ;;
esac