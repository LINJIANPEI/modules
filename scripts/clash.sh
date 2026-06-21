#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf

# 正确实现：将逗号分隔的字符串转换为 YAML 数组 ["a","b"]
to_yaml_array() {
    local input="$1"
    if [ -z "$input" ]; then
        echo "[]"
        return
    fi
    # 将 "a,b,c" 转换为 ["a","b","c"]
    echo "[$(echo "$input" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
}

# 从包名文件读取包名，生成逗号分隔的字符串（每行一个包名）
generate_uidlist_from_file() {
    local pkg_file="$PACKAGES_LIST_FILE"
    local result=""
    if [ -f "$pkg_file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | xargs)
            [ -z "$line" ] && continue
            [ "${line#\#}" != "$line" ] && continue
            if [ -z "$result" ]; then
                result="$line"
            else
                result="$result,$line"
            fi
        done < "$pkg_file"
    fi
    echo "$result"
}

# ======================== 主服务函数 ========================
start_service() {
    log Info "================开启代理=================" "${log_dir}/mihomo.log"

    # ---------- IPv6 配置 ----------
    ipv6_enabled=$(yamlcli -f "$YAML_FILE" get 'ipv6')
    if [ "$ipv6_enabled" = "false" ]; then
        accept_ra_val=0
        disable_ipv6_val=1
        log_msg="已关闭代理ipv6"
    else
        accept_ra_val=1
        disable_ipv6_val=0
        log_msg="已开启代理ipv6"
    fi

    for net in /proc/sys/net/ipv6/conf/[^l]*; do
        [ -e "$net" ] || continue
        ifname=$(basename "$net")
        [ "$ifname" = "all" ] || [ "$ifname" = "default" ] && continue
        case "$net" in
            *"/wlan"*) echo "$accept_ra_val" > "${net}/accept_ra" ;;
        esac
        echo "$disable_ipv6_val" > "${net}/disable_ipv6"
    done
    log Info "$log_msg" "${log_dir}/mihomo.log"

    # 检查是否已运行
    if is_process_running "mihomo"; then
        log Info "检测到mihomo已启动" "${log_dir}/mihomo.log"
        return 1
    fi

    # ---------- 读取包名列表（优先从文件） ----------
    local file_uidlist=$(generate_uidlist_from_file)
    if [ -n "$file_uidlist" ]; then
        uidlist="$file_uidlist"
        log Info "已从 app_packages.list 加载包名列表: $uidlist" "${log_dir}/mihomo.log"
    else
        log Info "使用 fun.conf 中的 uidlist: $uidlist" "${log_dir}/mihomo.log"
    fi

    # ---------- 转换为 YAML 数组 ----------
    uidlist_yaml=""
    iplist_yaml=""
    [ -n "$uidlist" ] && uidlist_yaml=$(to_yaml_array "$uidlist")
    [ -n "$iplist" ] && iplist_yaml=$(to_yaml_array "$iplist")

    # 根据 mode 选择字段名
    if [ "${mode}" = "blacklist" ]; then
        pkg_field="tun.exclude-package"
        ip_field="tun.route-exclude-address"
    elif [ "${mode}" = "whitelist" ]; then
        pkg_field="tun.include-package"
        ip_field="tun.route-address"
    else
        log Error "未知的 mode: ${mode}" "${log_dir}/mihomo.log"
        return 1
    fi

    # 写入 YAML 配置
    if [ -n "$uidlist_yaml" ]; then
        yamlcli -f "$YAML_FILE" set "$pkg_field" "$uidlist_yaml"
        log Info "已写入 $pkg_field = $uidlist_yaml" "${log_dir}/mihomo.log"
    fi
    if [ -n "$iplist_yaml" ]; then
        yamlcli -f "$YAML_FILE" set "$ip_field" "$iplist_yaml"
    fi

    # ---------- 检查必要端口或 TUN ----------
    tproxy_port=$(yamlcli -f "$YAML_FILE" get 'tproxy-port')
    tun_enable=$(yamlcli -f "$YAML_FILE" get 'tun.enable')
    valid_port=1
    case "$tproxy_port" in
        ''|*[!0-9]*) valid_port=0 ;;
        *)
            port_clean=$(echo "$tproxy_port" | sed 's/^0*//')
            [ -z "$port_clean" ] && port_clean=0
            [ "$port_clean" -lt 1 ] || [ "$port_clean" -gt 65535 ] && valid_port=0
            ;;
    esac
    if [ "$valid_port" -eq 0 ] && [ "$tun_enable" != "true" ]; then
        log Error "未检测到有效 tproxy-port 且 tun 未开启" "${log_dir}/mihomo.log"
        return 1
    fi

    # ---------- 测试配置 ----------
    if ! kernel_error=$("${module_dir}/bin/mihomo" \
        -d "${module_dir}/mihomoData" \
        -t -f "$YAML_FILE" 2>&1); then
        log Error "配置有误，启动失败" "${log_dir}/mihomo.log"
        log Error "$kernel_error" "${log_dir}/mihomo.log"
        return 1
    fi

    # ---------- 创建 TUN 设备（如果需要） ----------
    if [ "$tun_enable" = "true" ]; then
        mkdir -p /dev/net
        ln -sf /dev/tun /dev/net/tun
    fi

    # ---------- 启动 mihomo ----------
    if ! command -v busybox >/dev/null 2>&1; then
        log Error "未找到 busybox" "${log_dir}/mihomo.log"
        return 1
    fi
    if ! busybox --help 2>&1 | grep -q setuidgid; then
        log Error "busybox 不支持 setuidgid" "${log_dir}/mihomo.log"
        return 1
    fi
    if [ -z "${uid}" ] || [ -z "${gid}" ]; then
        log Error "uid 或 gid 未设置" "${log_dir}/mihomo.log"
        return 1
    fi

    calc_all_fd
    (
    # 设置 FD 限制
    ulimit -n "$FD_MIHOMO"
    nohup busybox setuidgid "${uid}:${gid}" "${module_dir}/bin/mihomo" \
        -d "${module_dir}/mihomoData" \
        -f "$YAML_FILE" \
        >> "${log_dir}/mihomoRun.log" 2>&1 &
    ) &  
    
    sleep 1
    if ! is_process_running "mihomo"; then
        log Error "mihomo 进程启动失败" "${log_dir}/mihomo.log"
        return 1
    fi

    log Info "代理模式: ${mode}" "${log_dir}/mihomo.log"
    log Info "mihomo内核已启动" "${log_dir}/mihomo.log"

    # ---------- 启动 ruleconverter 插件 ----------
    if [ "${enable_ruleconverter}" = "true" ] && [ -x "${module_dir}/bin/ruleconverter" ]; then
        nohup "${module_dir}/bin/ruleconverter" -port "${ruleconverter_port}" \
            >> "${log_dir}/ruleconverter.log" 2>&1 &
        log Info "ruleconverter 已启动，端口 ${ruleconverter_port}" "${log_dir}/mihomo.log"
    fi

    return 0
}

stop_service() {
    log Info "================停止代理=================" "${log_dir}/mihomo.log"
    kill_by_name mihomo
    log Info "已停止mihomo内核" "${log_dir}/mihomo.log"
    kill_by_name ruleconverter
    log Info "已停止ruleconverter插件" "${log_dir}/mihomo.log"
}

case "$1" in
    enable)
        start_service
        ;;
    display)
        stop_service
        ;;
    *)
        echo "Usage: $0 {enable|display}"
        exit 1
        ;;
esac