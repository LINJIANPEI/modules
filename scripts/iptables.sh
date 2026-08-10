#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf

# ======================== 状态 ========================

IPV6_STATUS=0

# ============== 函数：获取 UID 列表并返回 ==============

get_uids_from_file() {
    local list_file="$1"
    local uids=""
    local hd=""
    
    # 检查输入文件
    if [ ! -f "${list_file}" ]; then
        echo "错误：包名列表文件 ${list_file} 不存在" >&2
        return 1
    fi
    
    # 读取文件，过滤注释和空行
    while IFS= read -r line || [ -n "${line}" ]; do
        # 去除前后空格
        line=$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # 跳过空行和注释行
        [ -z "${line}" ] && continue
        case "$line" in
            \#*) continue ;;
        esac
        
        package="${line}"
        
        # 检查是否是头部标识 (格式: 数字>)
        nhd=$(echo "${package}" | awk -F ">" '/^[0-9]+>$/{print $1}')
        if [ "${nhd}" != "" ]; then
            hd="${nhd}"
            continue
        fi
        
        # 从系统获取 UID
        uid=""
        
        # 方法1：从 /data/system/packages.list 读取
        if [ -f "/data/system/packages.list" ]; then
            uid=$(grep "^${package} " /data/system/packages.list | awk '{print $2}' | head -1)
        fi
        
        # 方法2：使用 dumpsys package
        if [ -z "${uid}" ]; then
            uid=$(dumpsys package "${package}" 2>/dev/null | grep -E 'userId=|appId=' | head -1 | awk -F= '{print $NF}')
        fi
        
        # 如果找到 UID，添加到列表
        if [ -n "${uid}" ]; then
            uids="${uids} ${hd}${uid}"
        else
            echo "警告：${package} 未找到 UID" >&2
        fi
    done < "${list_file}"
    
    # 去除首尾空格并返回
    uids=$(echo "${uids}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    echo "${uids}"
}
# ======================== IPv6 控制 ========================

check_ipv6_support() {
    [ -f /proc/net/if_inet6 ] || return 1
    command -v ip6tables >/dev/null 2>&1 || return 1
    ip6tables -L >/dev/null 2>&1 || return 1
    return 0
}

_block_ipv6() {
    log Warn "IPv6 已阻断（MIHOMO_IPV6=false）" "${log_dir}/iptables.log"

    # 防重复插入
    ip6tables -C OUTPUT -j DROP 2>/dev/null || \
    ip6tables -I OUTPUT -j DROP 2>/dev/null

    IPV6_STATUS=2
}

init_ipv6() {
    if [ "$MIHOMO_IPV6" = "true" ]; then
        if check_ipv6_support; then
            IPV6_STATUS=1
            log Info "IPv6 启用" "${log_dir}/iptables.log"
        else
            IPV6_STATUS=2
            log Warn "IPv6 不可用（系统不支持）" "${log_dir}/iptables.log"
        fi
    else
        IPV6_STATUS=2
        _block_ipv6
    fi
}


# ======================== 统一的 iptables 命令 ========================

iptables_w() {
    # 检测是否包含 IPv6 特征
    local has_ipv6=0
    local has_ipv4=0
    
    for arg in "$@"; do
        case "$arg" in
            *::1*|*::*|*:.*|*"ip6"*|*"IPv6"*)
                has_ipv6=1
                ;;
            *127.0.0.1*|*[0-9]\.[0-9]\.[0-9]\.[0-9]*|*"ip4"*|*"IPv4"*)
                has_ipv4=1
                ;;
        esac
    done
    
    # 执行逻辑
    if [ "$has_ipv6" -eq 1 ] && [ "$has_ipv4" -eq 0 ]; then
        # 只有 IPv6 特征，只执行 IPv6
        [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = "1" ] && ip6tables -w 100 "$@" 2>/dev/null
    elif [ "$has_ipv4" -eq 1 ] && [ "$has_ipv6" -eq 0 ]; then
        # 只有 IPv4 特征，只执行 IPv4
        iptables -w 100 "$@" 2>/dev/null
    else
        # 没有特定 IP 特征或两者都有，同时执行
        iptables -w 100 "$@" 2>/dev/null
        [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = "1" ] && ip6tables -w 100 "$@" 2>/dev/null
    fi
}

# ======================== 统一的 ip 命令 ========================

ip_w() {
    # 检测是否包含 IPv6 特征
    local has_ipv6=0
    local has_ipv4=0
    
    for arg in "$@"; do
        case "$arg" in
            *::1*|*::*|*:.*|*"ip6"*|*"IPv6"*|-6)
                has_ipv6=1
                ;;
            *127.0.0.1*|*[0-9]\.[0-9]\.[0-9]\.[0-9]*|*"ip4"*|*"IPv4"*)
                has_ipv4=1
                ;;
        esac
    done
    
    # 执行逻辑
    if [ "$has_ipv6" -eq 1 ] && [ "$has_ipv4" -eq 0 ]; then
        # 只有 IPv6 特征，只执行 IPv6
        [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = "1" ] && ip -6 "$@" 2>/dev/null
    elif [ "$has_ipv4" -eq 1 ] && [ "$has_ipv6" -eq 0 ]; then
        # 只有 IPv4 特征，只执行 IPv4
        ip -4 "$@" 2>/dev/null
    else
        # 没有特定 IP 特征或两者都有，同时执行
        ip -4 "$@" 2>/dev/null
        [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = "1" ] && ip -6 "$@" 2>/dev/null
    fi
}

# ======================== REDIRECT ========================

setup_redirect() {
    iptables_w -t nat -N KERNEL_PRE
    iptables_w -t nat -F KERNEL_PRE

    for ip in ${reserved_ip} ; do
        iptables_w -t nat -A KERNEL_PRE -d "${ip}" -j RETURN
    done

    iptables_w -t nat -A KERNEL_PRE -p tcp -i lo -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}

    for ap in ${ap_list} ; do
        iptables_w -t nat -A KERNEL_PRE -p tcp -i "$ap" -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}
    done

    iptables_w -t nat -A PREROUTING -j KERNEL_PRE


    iptables_w -t nat -N KERNEL_OUT
    iptables_w -t nat -F KERNEL_OUT

    iptables_w -t nat -A KERNEL_OUT -m owner --uid-owner ${uid} --gid-owner ${gid} -j RETURN

    if [ "${mode}" = "blacklist" ] ; then
        apps=$(get_uids_from_file ${BLACK_LIST_FILE})
        for appuid in ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t nat -A KERNEL_OUT -m owner --uid-owner ${appuid} -j RETURN
            fi
        done
        iptables_w -t nat -A KERNEL_OUT -p tcp -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}

    elif [ "${mode}" = "whitelist" ] ; then
        apps=$(get_uids_from_file ${WHITE_LIST_FILE})
        for appuid in ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t nat -A KERNEL_OUT -p tcp -m owner --uid-owner ${appuid} -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}
            fi
        done

        iptables_w -t nat -A KERNEL_OUT -p tcp -m owner --uid-owner 0 -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}
        iptables_w -t nat -A KERNEL_OUT -p tcp -m owner --uid-owner 1052 -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}
        iptables_w -t nat -A KERNEL_OUT -p tcp -j RETURN
        
    elif [ "${mode}" = "global" ] ; then
        iptables_w -t nat -A KERNEL_OUT -p tcp -j REDIRECT --to-ports ${MIHOMO_REDIR_PORT}

    fi

    iptables_w -t nat -A OUTPUT -j KERNEL_OUT
    
    iptables_w -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_REDIR_PORT} -j REJECT
    iptables_w -A OUTPUT -d ::1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_REDIR_PORT} -j REJECT

}

cleanup_redirect() {
    log Info "清理 REDIRECT" "${log_dir}/iptables.log"

    iptables_w -t nat -D PREROUTING -j KERNEL_PRE
    iptables_w -t nat -F KERNEL_PRE
    iptables_w -t nat -X KERNEL_PRE

    iptables_w -t nat -D OUTPUT -j KERNEL_OUT
    iptables_w -t nat -F KERNEL_OUT
    iptables_w -t nat -X KERNEL_OUT

    iptables_w -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_REDIR_PORT} -j REJECT
    iptables_w -D OUTPUT -d ::1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_REDIR_PORT} -j REJECT
}

# ======================== TPROXY ========================

setup_tproxy() {
    if [ "$(sysctl -n net.ipv4.ip_forward)" -ne 1 ]; then
        sysctl -w net.ipv4.ip_forward=1
    fi

    if [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = 1 ] && [ "$(sysctl -n net.ipv6.conf.all.forwarding)" -ne 1 ] ; then
        sysctl -w net.ipv6.conf.all.forwarding=1
    fi

    ip_w rule add fwmark ${mark_id} table ${table_id} pref ${table_id}
    ip_w route add local default dev lo table ${table_id}

    iptables_w -t mangle -N KERNEL_PRE
    iptables_w -t mangle -F KERNEL_PRE

    iptables_w -t mangle -A KERNEL_PRE -p tcp -m socket --transparent -j MARK --set-xmark ${mark_id}
    iptables_w -t mangle -A KERNEL_PRE -p udp -m socket --transparent -j MARK --set-xmark ${mark_id}
    iptables_w -t mangle -A KERNEL_PRE -m socket -j RETURN

    for ip in ${reserved_ip} ; do
        iptables_w -t mangle -A KERNEL_PRE -d "${ip}" -j RETURN
    done

    iptables_w -t mangle -A KERNEL_PRE -p tcp -i lo -j TPROXY --on-port "${MIHOMO_TPROXY_PORT}" --tproxy-mark "${mark_id}"
    iptables_w -t mangle -A KERNEL_PRE -p udp -i lo -j TPROXY --on-port "${MIHOMO_TPROXY_PORT}" --tproxy-mark "${mark_id}"

    for ap in ${ap_list} ; do
        iptables_w -t mangle -A KERNEL_PRE -p tcp -i "$ap" -j TPROXY --on-port "${MIHOMO_TPROXY_PORT}" --tproxy-mark "${mark_id}"
        iptables_w -t mangle -A KERNEL_PRE -p udp -i "$ap" -j TPROXY --on-port "${MIHOMO_TPROXY_PORT}" --tproxy-mark "${mark_id}"
    done

    iptables_w -t mangle -A PREROUTING -j KERNEL_PRE

    iptables_w -t mangle -N KERNEL_OUT
    iptables_w -t mangle -F KERNEL_OUT

    iptables_w -t mangle -A KERNEL_OUT -m owner --uid-owner ${uid} --gid-owner ${gid} -j RETURN

    for ip in ${reserved_ip} ; do
        iptables_w -t mangle -A KERNEL_OUT -d "${ip}" -j RETURN
    done

    if [ "${mode}" = "blacklist" ] ; then
        apps=$(get_uids_from_file ${BLACK_LIST_FILE})
        for appuid in ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t mangle -A KERNEL_OUT -p tcp -m owner --uid-owner ${appuid} -j RETURN
                iptables_w -t mangle -A KERNEL_OUT -p udp -m owner --uid-owner ${appuid} -j RETURN
            fi
        done
        iptables_w -t mangle -A KERNEL_OUT -p tcp -j MARK --set-xmark ${mark_id}
        iptables_w -t mangle -A KERNEL_OUT -p udp -j MARK --set-xmark ${mark_id}
    elif [ "${mode}" = "whitelist" ] ; then
        apps=$(get_uids_from_file ${WHITE_LIST_FILE})
        for appuid in ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t mangle -A KERNEL_OUT -p tcp -m owner --uid-owner ${appuid} -j MARK --set-xmark ${mark_id}
                iptables_w -t mangle -A KERNEL_OUT -p udp -m owner --uid-owner ${appuid} -j MARK --set-xmark ${mark_id}
            fi
        done
        iptables_w -t mangle -A KERNEL_OUT -p tcp -m owner --uid-owner 0 -j MARK --set-xmark ${mark_id}
        iptables_w -t mangle -A KERNEL_OUT -p udp -m owner --uid-owner 0 -j MARK --set-xmark ${mark_id}

        iptables_w -t mangle -A KERNEL_OUT -p tcp -m owner --uid-owner 1052 -j MARK --set-xmark ${mark_id}
        iptables_w -t mangle -A KERNEL_OUT -p udp -m owner --uid-owner 1052 -j MARK --set-xmark ${mark_id}

        iptables_w -t mangle -A KERNEL_OUT -p tcp -j RETURN
        iptables_w -t mangle -A KERNEL_OUT -p udp -j RETURN
        
    elif [ "${mode}" = "global" ] ; then
        iptables_w -t mangle -A KERNEL_OUT -p tcp -j MARK --set-xmark ${mark_id}
        iptables_w -t mangle -A KERNEL_OUT -p udp -j MARK --set-xmark ${mark_id}
        
    fi

    iptables_w -t mangle -A OUTPUT -j KERNEL_OUT

    iptables_w -A OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_TPROXY_PORT} -j REJECT
    iptables_w -A OUTPUT -d ::1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_TPROXY_PORT} -j REJECT

}


cleanup_tproxy() {
    log Info "清理 TPROXY" "${log_dir}/iptables.log"

    ip_w rule del fwmark ${mark_id} table ${table_id} pref ${table_id}
    ip_w route del local default dev lo table ${table_id}

    iptables_w -t mangle -D PREROUTING -j KERNEL_PRE
    iptables_w -t mangle -F KERNEL_PRE
    iptables_w -t mangle -X KERNEL_PRE

    iptables_w -t mangle -D PREROUTING -p tcp -m socket --transparent -j MARK --set-xmark ${mark_id}
    iptables_w -t mangle -D PREROUTING -p udp -m socket --transparent -j MARK --set-xmark ${mark_id}
    iptables_w -t mangle -D PREROUTING -m socket -j RETURN

    iptables_w -t mangle -D OUTPUT -j KERNEL_OUT
    iptables_w -t mangle -F KERNEL_OUT
    iptables_w -t mangle -X KERNEL_OUT

    iptables_w -D OUTPUT -d 127.0.0.1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_TPROXY_PORT} -j REJECT

    iptables_w -D OUTPUT -d ::1 -p tcp -m owner --uid-owner ${uid} --gid-owner ${gid} -m tcp --dport ${MIHOMO_TPROXY_PORT} -j REJECT

}

# ======================== TUN ========================

setup_tun() {
    log Info "TUN 模式(严格路由)" "${log_dir}/iptables.log"

    iptables_w -I FORWARD -o "$MIHOMO_TUN_DEVICE" -j ACCEPT
    iptables_w -I FORWARD -i "$MIHOMO_TUN_DEVICE" -j ACCEPT
}

cleanup_tun() {
    log Info "清理 TUN(严格路由)" "${log_dir}/iptables.log"

    iptables_w -D FORWARD -o "$MIHOMO_TUN_DEVICE" -j ACCEPT 2>/dev/null
    iptables_w -D FORWARD -i "$MIHOMO_TUN_DEVICE" -j ACCEPT 2>/dev/null

}

setup_tuns() {
    log Info "TUN 模式" "${log_dir}/iptables.log"

    ip_w rule add fwmark ${mark_id} table ${table_id} pref ${pref_id}
    while [ "$(ip -4 route show table ${table_id} 2> /dev/null)" == "" ]
    do
        ip -4 route add default dev ${MIHOMO_TUN_DEVICE} table ${table_id}
    done

    if [ "$MIHOMO_IPV6" = "true" ] && [ "$IPV6_STATUS" = 1 ] ;then
        while [ "$(ip -6 route show table ${table_id} 2> /dev/null)" == "" ]
        do
            ip -6 route add default dev ${MIHOMO_TUN_DEVICE} table ${table_id}
        done
    fi
    iptables_w -A FORWARD -o ${MIHOMO_TUN_DEVICE} -j ACCEPT
    iptables_w -A FORWARD -i ${MIHOMO_TUN_DEVICE} -j ACCEPT
    iptables_w -t mangle -N KERNEL_PRE
    iptables_w -t mangle -A KERNEL_PRE -j MARK --set-xmark ${mark_id}
    iptables_w -t mangle -A PREROUTING -j KERNEL_PRE
    iptables_w -t mangle -N KERNEL_OUT
    iptables_w -t mangle -A KERNEL_OUT -m owner --uid-owner ${uid} --gid-owner ${gid} -j RETURN

    if [ "${mode}" = "blacklist" ] ; then
        apps=$(get_uids_from_file ${BLACK_LIST_FILE})
        for appuid in ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t mangle -A KERNEL_OUT -m owner --uid-owner ${appuid} -j RETURN
            fi  
        done
        iptables_w -t mangle -A KERNEL_OUT -j MARK --set-xmark ${mark_id}
    elif [ "${mode}" = "whitelist" ] ; then
        apps=$(get_uids_from_file ${WHITE_LIST_FILE})
        for appuid in  ${apps} ; do
            if [ -n "${appuid}" ]; then
                iptables_w -t mangle -A KERNEL_OUT -m owner --uid-owner ${appuid} -j MARK --set-xmark ${mark_id}
            fi
        done
        
            
    elif [ "${mode}" = "global" ] ; then
        iptables_w -t mangle -A KERNEL_OUT -j MARK --set-xmark ${mark_id}
        
    fi   
    iptables_w -t mangle -A OUTPUT -j KERNEL_OUT

}

cleanup_tuns() {
    log Info "清理 TUN" "${log_dir}/iptables.log"

    ip_w rule del fwmark ${mark_id} lookup ${table_id}
    ip_w route del default dev ${MIHOMO_TUN_DEVICE} table ${table_id}
    iptables_w -D FORWARD -o ${MIHOMO_TUN_DEVICE} -j ACCEPT	
    iptables_w -D FORWARD -i ${MIHOMO_TUN_DEVICE} -j ACCEPT
    iptables_w -t mangle -D OUTPUT -j KERNEL_OUT
    iptables_w -t mangle -F KERNEL_OUT
    iptables_w -t mangle -X KERNEL_OUT
    iptables_w -t mangle -D PREROUTING -j KERNEL_PRE
    iptables_w -t mangle -F KERNEL_PRE
    iptables_w -t mangle -X KERNEL_PRE

}

# ======================== 控制逻辑 ========================

start_routing() {
    log Info "启动路由规则" "${log_dir}/iptables.log"

    stop_routing >/dev/null 2>&1
    init_ipv6

    if [ "$MIHOMO_TUN_ENABLE" = "true" ]; then
        if [ "${MIHOMO_AUTOROUTE}" = "true" ];then
            setup_tun
        else
            setup_tuns
        fi
        return
    fi

    if iptables -m tproxy -h >/dev/null 2>&1; then
        log Info "TPROXY 模式" "${log_dir}/iptables.log"
        setup_tproxy
    else
        log Warn "REDIRECT 模式" "${log_dir}/iptables.log"
        setup_redirect
    fi
}

stop_routing() {
    log Info "停止路由规则" "${log_dir}/iptables.log"

    cleanup_tuns 2>/dev/null
    cleanup_tun 2>/dev/null
    cleanup_tproxy 2>/dev/null
    cleanup_redirect 2>/dev/null

    ip6tables -D OUTPUT -j DROP 2>/dev/null
}

# ======================== main ========================

case "$1" in
    enable) start_routing ;;
    disable) stop_routing ;;
    *)
        echo "用法: $0 {enable|disable}"
        exit 1
        ;;
esac