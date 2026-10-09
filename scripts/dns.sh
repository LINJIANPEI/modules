#!/system/bin/sh

# ============================================================================
# /data/adb/modules/Linlin/scripts/dns.sh
#
# DNS 劫持 + DoT/DoQ 封锁 + SNI 嗅探（不常驻）
#
# 用法: sh dns.sh {enable|disable|status} [DNS_PORT]
# ============================================================================

# ---------- 加载配置（含 log 函数） ----------
source /data/adb/modules/Linlin/fun.conf

# ---------- 确保日志目录存在 ----------
mkdir -p "${log_dir}" 2>/dev/null

# ---------- 变量兜底 ----------
: "${uid:=root}"
: "${gid:=net_raw}"
: "${redir_port:=5591}"
: "${sni_ports:=443,8443}"
: "${sni_queue:=0}"
: "${block_ipv6_dns:=false}"

# DNS 端口优先级：命令行 > mihomo > adguard
if [ -n "$2" ]; then
    DNS_PORT="$2"
elif [ "${enable_mihomo}" = "true" ] && [ "${MIHOMO_DNS_ENABLE}" = "true" ]; then
    DNS_PORT="${MIHOMO_DNS_PORT:-$redir_port}"
else
    DNS_PORT="$redir_port"
fi

# ---------- 链名 ----------
CHAIN4="REDIRECT_DNS"
CHAIN6="REDIRECT_DNS6"
CHAIN_BLK6="BLOCK_DNS6"
CHAIN_DOT="AGH_DOT"
CHAIN_DOT6="AGH_DOT6"
CHAIN_SNI="AGH_SNI"

# ============================================================================
# IPv6 NAT 能力检测
# ============================================================================
check_ipv6_nat_support() {
    [ "$block_ipv6_dns" = "true" ] && return 1

    ip6tables -w 2 -t nat -L >/dev/null 2>&1 || return 1

    ip6tables -w 2 -t nat -A PREROUTING -p tcp --dport 65534 \
        -j REDIRECT --to-port 65534 >/dev/null 2>&1 || return 1
    ip6tables -w 2 -t nat -D PREROUTING -p tcp --dport 65534 \
        -j REDIRECT --to-port 65534 >/dev/null 2>&1
    return 0
}

# ============================================================================
# DNS 劫持链（IPv4 + IPv6）
# ============================================================================
rebuild_dns4() {
    iptables -w 2 -t nat -N "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4"
    iptables -w 2 -t nat -C OUTPUT -j "$CHAIN4" 2>/dev/null || \
        iptables -w 2 -t nat -I OUTPUT 1 -j "$CHAIN4"

    # 放行 DNS 进程自己的上游查询（避免自环）
    iptables -w 2 -t nat -A "$CHAIN4" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    # ignore_dest_list
    for s in ${ignore_dest_list}; do
        case "$s" in *:*) continue ;; esac
        iptables -w 2 -t nat -A "$CHAIN4" -d "$s" -j RETURN
    done

    # ignore_src_list
    for s in ${ignore_src_list}; do
        case "$s" in *:*) continue ;; esac
        iptables -w 2 -t nat -A "$CHAIN4" -s "$s" -j RETURN
    done

    # 劫持所有明文 53
    iptables -w 2 -t nat -A "$CHAIN4" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    iptables -w 2 -t nat -A "$CHAIN4" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
}

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
}

rebuild_dns6_block() {
    ip6tables -w 2 -t filter -N "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK6"
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK6" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK6"

    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" -p udp --dport 53 -j DROP
    ip6tables -w 2 -t filter -A "$CHAIN_BLK6" -p tcp --dport 53 -j DROP
}

# ============================================================================
# DoT / DoQ 封锁
# ============================================================================
rebuild_dot4() {
    iptables -w 2 -N "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -F "$CHAIN_DOT"
    iptables -w 2 -C OUTPUT -j "$CHAIN_DOT" 2>/dev/null || \
        iptables -w 2 -I OUTPUT 1 -j "$CHAIN_DOT"

    # 放行 DNS 进程自己（避免阻断上游 DoT/DoH）
    iptables -w 2 -A "$CHAIN_DOT" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    iptables -w 2 -A "$CHAIN_DOT" -p tcp --dport 853 -j REJECT
    iptables -w 2 -A "$CHAIN_DOT" -p udp --dport 853 \
        -j REJECT --reject-with icmp-port-unreachable
    iptables -w 2 -A "$CHAIN_DOT" -p udp --dport 443 \
        -j REJECT --reject-with icmp-port-unreachable
}

rebuild_dot6() {
    ip6tables -w 2 -t filter -N "$CHAIN_DOT6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_DOT6"
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_DOT6" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_DOT6"

    ip6tables -w 2 -t filter -A "$CHAIN_DOT6" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN
    ip6tables -w 2 -t filter -A "$CHAIN_DOT6" -p tcp --dport 853 -j REJECT
    ip6tables -w 2 -t filter -A "$CHAIN_DOT6" -p udp --dport 853 \
        -j REJECT --reject-with icmp6-port-unreachable
    ip6tables -w 2 -t filter -A "$CHAIN_DOT6" -p udp --dport 443 \
        -j REJECT --reject-with icmp6-port-unreachable
}

# ============================================================================
# SNI NFQUEUE
# ============================================================================
rebuild_sni() {
    # ---- IPv4 ----
    iptables -w 2 -t filter -N "$CHAIN_SNI" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_SNI"
    iptables -w 2 -t filter -A "$CHAIN_SNI" -o lo -j RETURN
    iptables -w 2 -t filter -A "$CHAIN_SNI" \
        -p tcp -m multiport --dports "$sni_ports" --tcp-flags ALL ACK -j RETURN
    iptables -w 2 -t filter -A "$CHAIN_SNI" \
        -p tcp -m multiport --dports "$sni_ports" \
        --tcp-flags SYN,FIN,RST NONE \
        -j NFQUEUE --queue-num "$sni_queue" --queue-bypass
    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_SNI" 2>/dev/null || \
        iptables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_SNI"

    # ---- IPv6 ----
    ip6tables -w 2 -t filter -N "$CHAIN_SNI" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_SNI"
    ip6tables -w 2 -t filter -A "$CHAIN_SNI" -o lo -j RETURN
    ip6tables -w 2 -t filter -A "$CHAIN_SNI" \
        -p tcp -m multiport --dports "$sni_ports" --tcp-flags ALL ACK -j RETURN
    ip6tables -w 2 -t filter -A "$CHAIN_SNI" \
        -p tcp -m multiport --dports "$sni_ports" \
        --tcp-flags SYN,FIN,RST NONE \
        -j NFQUEUE --queue-num "$sni_queue" --queue-bypass
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_SNI" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_SNI"
}

# ============================================================================
# 全量重建
# ============================================================================
rebuild_all() {
    log Info "重建所有规则" "${log_dir}/dns.log"

    rebuild_dns4

    if check_ipv6_nat_support; then
        rebuild_dns6
        # IPv6 有 REDIRECT 时不需要 BLOCK
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_BLK6" 2>/dev/null
    else
        rebuild_dns6_block
        # 清掉残留的 REDIRECT_DNS6
        ip6tables -w 2 -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -F "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -X "$CHAIN6" 2>/dev/null
    fi

    rebuild_dot4
    rebuild_dot6
    rebuild_sni
}

# ============================================================================
# 首次部署
# ============================================================================
first_setup() {
    log Info "开始部署 DNS 劫持 (DNS_PORT=$DNS_PORT)" "${log_dir}/dns.log"

    [ "$(settings get global private_dns_mode)" != "off" ] && \
        settings put global private_dns_mode off
    settings put global private_dns_specifier ""
    [ -d "/data/system/ifw" ] && rm -rf /data/system/ifw/*

    rebuild_all

    # 重启网络栈让 DNS 立即生效
    for s in 1 0; do
        settings put global airplane_mode_on $s
        am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
    done

    log Info "DNS 劫持部署完成" "${log_dir}/dns.log"
}

# ============================================================================
# stop
# ============================================================================
stop_all() {
    log Info "清理 DNS 规则" "${log_dir}/dns.log"

    # IPv4
    iptables -w 2 -t nat -D OUTPUT -j "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -X "$CHAIN4" 2>/dev/null
    iptables -w 2 -D OUTPUT -j "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -F "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -X "$CHAIN_DOT" 2>/dev/null

    # IPv6
    ip6tables -w 2 -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t nat -F "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t nat -X "$CHAIN6" 2>/dev/null
    ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -X "$CHAIN_BLK6" 2>/dev/null
    ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_DOT6" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_DOT6" 2>/dev/null
    ip6tables -w 2 -t filter -X "$CHAIN_DOT6" 2>/dev/null

    # SNI
    iptables -w 2 -t filter -D OUTPUT -j "$CHAIN_SNI" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_SNI" 2>/dev/null
    iptables -w 2 -t filter -X "$CHAIN_SNI" 2>/dev/null
    ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_SNI" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_SNI" 2>/dev/null
    ip6tables -w 2 -t filter -X "$CHAIN_SNI" 2>/dev/null

    log Info "DNS 规则清理完成" "${log_dir}/dns.log"
}

# ============================================================================
# status
# ============================================================================
show_status() {
    echo "=== DNS (IPv4) ==="
    iptables -t nat -S "$CHAIN4" 2>/dev/null || echo "  不存在"
    echo
    echo "=== DNS (IPv6) ==="
    ip6tables -t nat -S "$CHAIN6" 2>/dev/null || \
        ip6tables -t filter -S "$CHAIN_BLK6" 2>/dev/null || echo "  不存在"
    echo
    echo "=== DoT (IPv4) ==="
    iptables -S "$CHAIN_DOT" 2>/dev/null || echo "  不存在"
    echo
    echo "=== SNI ==="
    iptables -t filter -S "$CHAIN_SNI" 2>/dev/null || echo "  不存在"
    echo
    echo "=== 计数器 ==="
    iptables -t nat -L "$CHAIN4" -n -v --line-numbers 2>/dev/null
    echo
    echo "=== 端口监听 ==="
    ss -lunp 2>/dev/null | grep ":${DNS_PORT} " || echo "  ${DNS_PORT} 未监听"
}

# ============================================================================
# 入口
# ============================================================================
case "$1" in
    enable|"")
        first_setup
        ;;
    disable)
        stop_all
        ;;
    status)
        show_status
        ;;
    *)
        echo "用法: $0 {enable|disable|status} [DNS_PORT]"
        exit 1
        ;;
esac