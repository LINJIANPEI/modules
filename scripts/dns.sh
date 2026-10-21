#!/system/bin/sh

# ============================================================================
# /data/adb/modules/Linlin/scripts/dns.sh
#
# DNS 劫持 + DoT/DoQ 封锁 + SNI 嗅探（不常驻）
#
# 用法: sh dns.sh {enable|disable|status} [DNS_PORT]
#
# IPv6 策略：
#   block_ipv6_dns=false + nat 可用  → IPv6 劫持，与 IPv4 同步
#   block_ipv6_dns=true              → IPv6 DNS 阻断（DROP 53）
#   nat 不可用（无论变量）           → IPv6 DNS 阻断兜底（DROP 53）
#   ip6tables 不存在                 → 禁用 IPv6 网络栈（disable_ipv6=1）全断
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

# ---------- IPv6 能力标志 ----------
IPV6_CMD_OK=false      # ip6tables 命令是否存在
IPV6_NAT_OK=false      # IPv6 nat 表 + REDIRECT 是否可用
IPV6_STACK_OFF=false   # 是否由本脚本禁用了 IPv6 网络栈
IPV6_PREV_ALL=""
IPV6_PREV_DEFAULT=""

# ---------- DNS 端口 ----------
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
# IPv6 网络栈禁用 / 恢复
# ============================================================================
block_ipv6_stack() {
    log Warn "尝试禁用 IPv6 网络栈，阻断所有 IPv6 流量" "${log_dir}/dns.log"
    IPV6_PREV_ALL=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    IPV6_PREV_DEFAULT=$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)

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
        IPV6_STACK_OFF=true
        log Warn "IPv6 网络栈已禁用（重启后自动恢复，或 disable 脚本恢复）" "${log_dir}/dns.log"
        log Warn "注意：可能影响 VoLTE/VoWiFi 等依赖 IPv6 的业务" "${log_dir}/dns.log"
    else
        log Warn "禁用 IPv6 网络栈失败，IPv6 流量仍可能绕过 DNS 劫持" "${log_dir}/dns.log"
    fi
}

unblock_ipv6_stack() {
    [ "$IPV6_STACK_OFF" = "true" ] || return 0

    log Info "恢复 IPv6 网络栈（还原为部署前的值）" "${log_dir}/dns.log"
    if [ -n "$IPV6_PREV_ALL" ]; then
        echo "$IPV6_PREV_ALL" > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
    fi
    if [ -n "$IPV6_PREV_DEFAULT" ]; then
        echo "$IPV6_PREV_DEFAULT" > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
    fi
    IPV6_STACK_OFF=false
}

# ============================================================================
# IPv6 能力检测（带打印）
# ============================================================================
detect_ipv6() {
    IPV6_CMD_OK=false
    IPV6_NAT_OK=false

    # ---- 命令都不存在 → 只能全断 ----
    if ! command -v ip6tables >/dev/null 2>&1; then
        log Warn "ip6tables 命令不存在 → 无法建立 IPv6 规则，禁用 IPv6 网络栈兜底" "${log_dir}/dns.log"
        block_ipv6_stack
        return 1
    fi
    IPV6_CMD_OK=true

    # ---- 用户显式要求阻断 DNS ----
    if [ "$block_ipv6_dns" = "true" ]; then
        log Info "block_ipv6_dns=true → IPv6 DNS 走 DROP 阻断" "${log_dir}/dns.log"
        return 0
    fi

    # ---- nat 表不可用 → 想劫持也劫持不了，DROP 兜底 ----
    if ! ip6tables -w 2 -t nat -L >/dev/null 2>&1; then
        log Warn "IPv6 nat 不可用（block_ipv6_dns=false 但无法劫持）→ IPv6 DNS 走 DROP 阻断兜底" "${log_dir}/dns.log"
        return 0
    fi

    # ---- REDIRECT 写入测试 ----
    if ! ip6tables -w 2 -t nat -A PREROUTING -p tcp --dport 65534 \
            -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
        log Warn "IPv6 nat REDIRECT 写入失败 → IPv6 DNS 走 DROP 阻断兜底" "${log_dir}/dns.log"
        return 0
    fi
    IPV6_NAT_OK=true

    if ! ip6tables -w 2 -t nat -D PREROUTING -p tcp --dport 65534 \
            -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
        log Warn "IPv6 nat 测试规则删除失败，请手动执行:" "${log_dir}/dns.log"
        log Warn "  ip6tables -t nat -D PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534" "${log_dir}/dns.log"
    fi

    log Info "IPv6 nat REDIRECT 可用 → IPv6 DNS 劫持（与 IPv4 同步）" "${log_dir}/dns.log"
    return 0
}

# ============================================================================
# DNS 劫持链
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
# SNI NFQUEUE（IPv4 总建，IPv6 按命令能力）
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
    if [ "$IPV6_CMD_OK" != "true" ]; then
        log Warn "跳过 SNI IPv6 规则（ip6tables 不可用）" "${log_dir}/dns.log"
        return
    fi
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
    log Info "重建所有规则 (DNS_PORT=$DNS_PORT, block_ipv6_dns=$block_ipv6_dns)" "${log_dir}/dns.log"
    detect_ipv6

    # ---- DNS IPv4 ----
    rebuild_dns4

    # ---- DNS IPv6 ----
    if [ "$IPV6_CMD_OK" != "true" ]; then
        log Warn "跳过 DNS IPv6 规则（已禁用 IPv6 栈，无 IPv6 流量）" "${log_dir}/dns.log"
    elif [ "$IPV6_NAT_OK" = "true" ]; then
        rebuild_dns6
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_BLK6" 2>/dev/null
    else
        rebuild_dns6_block
        ip6tables -w 2 -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -F "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -X "$CHAIN6" 2>/dev/null
    fi

    # ---- DoT ----
    rebuild_dot4
    if [ "$IPV6_CMD_OK" = "true" ]; then
        rebuild_dot6
    else
        log Warn "跳过 DoT IPv6 规则（ip6tables 不可用）" "${log_dir}/dns.log"
    fi

    # ---- SNI ----
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

    # 先恢复 IPv6 网络栈
    unblock_ipv6_stack

    _v6cmd=false
    command -v ip6tables >/dev/null 2>&1 && _v6cmd=true

    # ---- IPv4 ----
    iptables -w 2 -t nat -D OUTPUT -j "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -X "$CHAIN4" 2>/dev/null
    iptables -w 2 -D OUTPUT -j "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -F "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -X "$CHAIN_DOT" 2>/dev/null
    iptables -w 2 -t filter -D OUTPUT -j "$CHAIN_SNI" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_SNI" 2>/dev/null
    iptables -w 2 -t filter -X "$CHAIN_SNI" 2>/dev/null

    # ---- IPv6 ----
    if [ "$_v6cmd" = "true" ]; then
        ip6tables -w 2 -t nat -D OUTPUT -j "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -F "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t nat -X "$CHAIN6" 2>/dev/null
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_BLK6" 2>/dev/null
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_DOT6" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_DOT6" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_DOT6" 2>/dev/null
        ip6tables -w 2 -t filter -D OUTPUT -j "$CHAIN_SNI" 2>/dev/null
        ip6tables -w 2 -t filter -F "$CHAIN_SNI" 2>/dev/null
        ip6tables -w 2 -t filter -X "$CHAIN_SNI" 2>/dev/null
    else
        log Warn "跳过 IPv6 规则清理（ip6tables 不可用）" "${log_dir}/dns.log"
    fi

    log Info "DNS 规则清理完成" "${log_dir}/dns.log"
}

# ============================================================================
# status（IPv4 / IPv6 全部显示）
# ============================================================================
show_status() {
    echo "=== IPv6 能力 ==="
    if command -v ip6tables >/dev/null 2>&1; then
        echo "  ip6tables 命令 : 存在"
        if ip6tables -w 2 -t nat -L >/dev/null 2>&1; then
            echo "  IPv6 nat 表    : 可用（DNS 可劫持）"
        else
            echo "  IPv6 nat 表    : 不可用（DNS 走 DROP 模式）"
        fi
    else
        echo "  ip6tables 命令 : 不存在（IPv6 规则全部跳过）"
    fi

    _stack=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    case "$_stack" in
        1) echo "  IPv6 网络栈    : 已禁用（disable_ipv6=1，全阻断）" ;;
        0) echo "  IPv6 网络栈    : 启用中（disable_ipv6=0）" ;;
        *) echo "  IPv6 网络栈    : /proc 入口不存在，无法判断" ;;
    esac
    echo "  block_ipv6_dns : ${block_ipv6_dns}"
    echo

    echo "=== DNS (IPv4) ==="
    iptables -t nat -S "$CHAIN4" 2>/dev/null || echo "  不存在"
    echo
    echo "=== DNS (IPv6) ==="
    if command -v ip6tables >/dev/null 2>&1; then
        _found=0
        if ip6tables -t nat -S "$CHAIN6" 2>/dev/null; then
            echo "  [REDIRECT 模式]"
            _found=1
        fi
        if ip6tables -t filter -S "$CHAIN_BLK6" 2>/dev/null; then
            echo "  [DROP 模式]"
            _found=1
        fi
        [ "$_found" = "0" ] && echo "  不存在"
    else
        echo "  跳过（ip6tables 不存在）"
    fi
    echo

    echo "=== DoT (IPv4) ==="
    iptables -S "$CHAIN_DOT" 2>/dev/null || echo "  不存在"
    echo
    echo "=== DoT (IPv6) ==="
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t filter -S "$CHAIN_DOT6" 2>/dev/null || echo "  不存在"
    else
        echo "  跳过（ip6tables 不存在）"
    fi
    echo

    echo "=== SNI (IPv4) ==="
    iptables -t filter -S "$CHAIN_SNI" 2>/dev/null || echo "  不存在"
    echo
    echo "=== SNI (IPv6) ==="
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t filter -S "$CHAIN_SNI" 2>/dev/null || echo "  不存在"
    else
        echo "  跳过（ip6tables 不存在）"
    fi
    echo

    echo "=== 计数器 ==="
    iptables -t nat -L "$CHAIN4" -n -v --line-numbers 2>/dev/null
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