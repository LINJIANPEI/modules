#!/system/bin/sh
# ============================================================================
# /data/adb/modules/Linlin/scripts/dns.sh
#
# DNS 劫持 + DoT/DoQ/DoH3 封锁（不常驻，无 SNI）
#
# 用法: sh dns.sh {enable|disable|status} [DNS_PORT]
#
# IPv6 DNS 53 三档：
#   block_ipv6_dns=false + nat 可用   → IPv6 同步 REDIRECT
#   block_ipv6_dns=false + nat 不可用 → 不碰 IPv6 DNS，保留原生解析
#   block_ipv6_dns=true               → IPv6 DNS 53 DROP
#
# ip6tables 命令不存在：
#   → 禁用 IPv6 网络栈（disable_ipv6=1），全部 IPv6 流量中断
#   → 跳过所有 IPv6 规则（DNS / DoT / DoQ）
#   → 原值存文件，disable 时恢复
#
# 853(tcp/udp) + udp443：与 IPv4 无条件同步（ip6tables 可用时）
# ============================================================================

source /data/adb/modules/Linlin/fun.conf
mkdir -p "${log_dir}" 2>/dev/null

# ---------- 统一日志文件 ----------
LOG_FILE="${log_dir}/dns.log"

# 脚本自身 stderr 也进 dns.log（fun.conf 的 log 函数仍显式传参，双保险）
exec 2>>"$LOG_FILE" 2>/dev/null || true

# ---------- 变量兜底 ----------
: "${uid:=root}"
: "${gid:=net_raw}"
: "${redir_port:=5591}"
: "${block_ipv6_dns:=false}"

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
CHAIN_BLK="BLOCK_ENC_DNS"

# ---------- IPv6 能力 ----------
IPV6_CMD_OK=false
IPV6_NAT_OK=false
IPV6_PREV_FILE="${log_dir}/ipv6_prev.conf"

# ============================================================================
# IPv6 网络栈禁用 / 恢复
# ============================================================================
block_ipv6_stack() {
    log Warn "ip6tables 不可用 → 禁用 IPv6 网络栈兜底" "$LOG_FILE"

    if [ ! -f "$IPV6_PREV_FILE" ]; then
        _a=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        _d=$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)
        {
            [ -n "$_a" ] && echo "ALL=$_a"
            [ -n "$_d" ] && echo "DEFAULT=$_d"
        } > "$IPV6_PREV_FILE" 2>/dev/null
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
        log Warn "IPv6 网络栈已禁用（disable_ipv6=1）" "$LOG_FILE"
        log Warn "所有 IPv6 流量中断：DNS/DoT/DoQ/网页；可能影响 VoLTE/VoWiFi" "$LOG_FILE"
        log Warn "重启或 sh dns.sh disable 恢复" "$LOG_FILE"
    else
        log Warn "禁用 IPv6 网络栈失败，IPv6 流量仍可能绕过 DNS 劫持" "$LOG_FILE"
    fi
}

unblock_ipv6_stack() {
    if [ -f "$IPV6_PREV_FILE" ]; then
        _a=$(grep '^ALL=' "$IPV6_PREV_FILE" 2>/dev/null | cut -d= -f2)
        _d=$(grep '^DEFAULT=' "$IPV6_PREV_FILE" 2>/dev/null | cut -d= -f2)
        [ -z "$_a" ] && _a=0
        [ -z "$_d" ] && _d=0

        echo "$_a" > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
        echo "$_d" > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
        rm -f "$IPV6_PREV_FILE"
        log Info "IPv6 网络栈已恢复（all=$_a, default=$_d）" "$LOG_FILE"
        return 0
    fi

    _cur=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    if [ "$_cur" = "1" ]; then
        echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
        echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
        log Info "IPv6 网络栈已恢复为默认（0）" "$LOG_FILE"
    fi
}

# ============================================================================
# IPv6 能力探测
# ============================================================================
detect_ipv6() {
    IPV6_CMD_OK=false
    IPV6_NAT_OK=false

    if ! command -v ip6tables >/dev/null 2>&1; then
        block_ipv6_stack
        return 1
    fi
    IPV6_CMD_OK=true

    ip6tables -w 2 -t nat -L >/dev/null 2>&1 || return 0

    if ip6tables -w 2 -t nat -A PREROUTING -p tcp --dport 65534 \
            -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
        IPV6_NAT_OK=true
        ip6tables -w 2 -t nat -D PREROUTING -p tcp --dport 65534 \
            -j REDIRECT --to-port 65534 2>/dev/null
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
# DNS 53：IPv6 劫持（同步模式）
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
}

# ============================================================================
# DNS 53：IPv6 DROP（block_ipv6_dns=true）
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
}

# ---------- 内部清理助手 ----------
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

# ============================================================================
# 853(tcp/udp) + udp443：v4/v6 同步
# ============================================================================
rebuild_block4() {
    iptables -w 2 -t filter -N "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_BLK"
    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || \
        iptables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK"

    iptables -w 2 -t filter -A "$CHAIN_BLK" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    iptables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j REJECT
    iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 \
        -j REJECT --reject-with icmp-port-unreachable
    iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 \
        -j REJECT --reject-with icmp-port-unreachable
}

rebuild_block6() {
    ip6tables -w 2 -t filter -N "$CHAIN_BLK" 2>/dev/null
    ip6tables -w 2 -t filter -F "$CHAIN_BLK"
    ip6tables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || \
        ip6tables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK"

    ip6tables -w 2 -t filter -A "$CHAIN_BLK" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j REJECT
    ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 \
        -j REJECT --reject-with icmp6-port-unreachable
    ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 \
        -j REJECT --reject-with icmp6-port-unreachable
}

# ============================================================================
# 全量重建
# ============================================================================
rebuild_all() {
    log Info "重建规则 (DNS_PORT=$DNS_PORT, block_ipv6_dns=$block_ipv6_dns)" "$LOG_FILE"
    detect_ipv6

    rebuild_dns4

    if [ "$IPV6_CMD_OK" != "true" ]; then
        log Warn "IPv6 网络栈已禁用 → 跳过全部 IPv6 规则（DNS/DoT/DoQ）" "$LOG_FILE"
    else
        if [ "$block_ipv6_dns" = "true" ]; then
            log Info "block_ipv6_dns=true → IPv6 DNS 走 DROP" "$LOG_FILE"
            rebuild_dns6_block
            _clear_dns6
        elif [ "$IPV6_NAT_OK" = "true" ]; then
            log Info "block_ipv6_dns=false + nat 可用 → IPv6 DNS 同步劫持" "$LOG_FILE"
            rebuild_dns6
            _clear_dns6_blk
        else
            log Warn "block_ipv6_dns=false 但 nat 不可用 → 不碰 IPv6 DNS" "$LOG_FILE"
            _clear_dns6
            _clear_dns6_blk
        fi

        rebuild_block6
    fi

    rebuild_block4

    if [ "$IPV6_CMD_OK" = "true" ]; then
        log Info "853/udp443 已封锁（IPv4 + IPv6）" "$LOG_FILE"
    else
        log Warn "853/udp443 仅封锁 IPv4（IPv6 已整栈禁用）" "$LOG_FILE"
    fi
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

    rebuild_all

    for s in 1 0; do
        settings put global airplane_mode_on $s
        am broadcast -a android.intent.action.AIRPLANE_MODE >/dev/null 2>&1
    done

    log Info "部署完成" "$LOG_FILE"
}

# ============================================================================
# 清理
# ============================================================================
stop_all() {
    log Info "清理规则" "$LOG_FILE"

    unblock_ipv6_stack

    # ---- IPv4 ----
    iptables -w 2 -t nat -D OUTPUT -j "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -F "$CHAIN4" 2>/dev/null
    iptables -w 2 -t nat -X "$CHAIN4" 2>/dev/null
    iptables -w 2 -t filter -D OUTPUT -j "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -X "$CHAIN_BLK" 2>/dev/null

    # ---- IPv6 ----
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

    # ---- 旧版 SNI 残留（IPv4）----
    iptables -w 2 -t filter -D OUTPUT -j AGH_SNI 2>/dev/null
    iptables -w 2 -t filter -F AGH_SNI 2>/dev/null
    iptables -w 2 -t filter -X AGH_SNI 2>/dev/null

    log Info "清理完成" "$LOG_FILE"
}

# ============================================================================
# status（人类可读输出走 stdout，不写日志）
# ============================================================================
show_status() {
    echo "=== IPv6 能力 ==="
    if command -v ip6tables >/dev/null 2>&1; then
        echo "  ip6tables      : 存在"
        ip6tables -w 2 -t nat -L >/dev/null 2>&1 \
            && echo "  IPv6 nat       : 可用" \
            || echo "  IPv6 nat       : 不可用"
    else
        echo "  ip6tables      : 不存在（栈被禁用中）"
    fi
    echo "  disable_ipv6   : $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)"
    echo "  block_ipv6_dns : ${block_ipv6_dns}"
    [ -f "$IPV6_PREV_FILE" ] && echo "  栈原值文件     : $(tr '\n' ' ' < "$IPV6_PREV_FILE")"
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
    command -v ip6tables >/dev/null 2>&1 && \
        ip6tables -t nat -L "$CHAIN6" -n -v 2>/dev/null
    echo

    echo "=== 端口监听 ==="
    ss -lunp 2>/dev/null | grep -E ":${DNS_PORT}(\s|$)" || echo "  ${DNS_PORT} 未监听"
}

# ============================================================================
# 入口
# ============================================================================
case "$1" in
    enable|"") first_setup ;;
    disable)   stop_all ;;
    status)    show_status ;;
    *) echo "用法: $0 {enable|disable|status} [DNS_PORT]"; exit 1 ;;
esac