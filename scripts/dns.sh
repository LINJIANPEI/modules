#!/system/bin/sh
# ============================================================================
# /data/adb/modules/Linlin/scripts/dns.sh
#
# DNS 劫持 + DoT/DoQ/DoH3 封锁（不常驻，无 SNI）
#
# 用法: sh dns.sh {enable|disable|status} [DNS_PORT]
#
# IPv6 DNS 53（优先保留栈，DNS 53 绝不泄露）：
#   block_ipv6_dns=true  → 首选 filter DROP，失败回退 nat REDIRECT，都失败禁用栈
#   block_ipv6_dns=false → 首选 nat REDIRECT，失败回退 filter DROP，都失败禁用栈
#   ip6tables 不存在     → 禁用 IPv6 栈
#
# 853(tcp/udp) + udp443（尽量丢弃）：
#   首选 filter DROP（静默丢包）
#   DROP 建失败 → 降级 REJECT（快速失败）
#   都失败 → IPv6 可选禁用栈（ipv6_block_fail_disable_stack=true），IPv4 仅告警
#
# 所有规则建立后都用 -C 校验，失败自动降级，绝不静默通过。
# ============================================================================

source /data/adb/modules/Linlin/fun.conf
mkdir -p "${log_dir}" 2>/dev/null

LOG_FILE="${log_dir}/dns.log"
exec 2>>"$LOG_FILE" 2>/dev/null || true

# ---------- 变量兜底 ----------
: "${uid:=root}"
: "${gid:=net_raw}"
: "${redir_port:=5591}"
: "${block_ipv6_dns:=false}"
: "${ipv6_block_fail_disable_stack:=false}"

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
IPV6_FILTER_OK=false
IPV6_MODE=""
IPV6_PREV_FILE="${log_dir}/ipv6_prev.conf"

# ============================================================================
# IPv6 网络栈禁用 / 恢复
# ============================================================================
block_ipv6_stack() {
    _reason="${1:-未指定原因}"
    log Warn "${_reason} → 禁用 IPv6 网络栈兜底" "$LOG_FILE"

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
    if [ -f "$IPV6_PREV_FILE" ]; then
        _a=$(grep '^ALL=' "$IPV6_PREV_FILE" 2>/dev/null | cut -d= -f2)
        _d=$(grep '^DEFAULT=' "$IPV6_PREV_FILE" 2>/dev/null | cut -d= -f2)
        [ -z "$_a" ] && _a=0
        [ -z "$_d" ] && _d=0

        echo "$_a" > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
        echo "$_d" > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null

        _cur_a=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        _cur_d=$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)
        if [ "$_cur_a" = "$_a" ] && [ "$_cur_d" = "$_d" ]; then
            rm -f "$IPV6_PREV_FILE"
            log Info "IPv6 网络栈已恢复（all=$_a, default=$_d，校验通过）" "$LOG_FILE"
        else
            log Warn "IPv6 网络栈恢复失败（当前 all=$_cur_a default=$_cur_d，期望 all=$_a default=$_d），保留备份文件" "$LOG_FILE"
        fi
        return 0
    fi

    _cur=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    if [ "$_cur" = "1" ]; then
        echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
        echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
        _cur2=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [ "$_cur2" = "0" ]; then
            log Info "IPv6 网络栈已恢复为默认（0，校验通过）" "$LOG_FILE"
        else
            log Warn "IPv6 网络栈恢复为默认失败（当前=$_cur2）" "$LOG_FILE"
        fi
    fi
}

# ============================================================================
# IPv6 能力探测（只探测，不建规则）
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
# DNS 53：IPv6 REDIRECT（nat）
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
# DNS 53：IPv6 DROP（filter）
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
# 应用 IPv6 DNS 规则：首选 → 校验 → 回退 → 再校验 → 都失败禁用栈
# ============================================================================
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
# 853(tcp/udp) + udp443：尽量丢弃
# 首选 filter DROP，失败降级 REJECT，都失败返回 1
# ============================================================================
rebuild_block4() {
    iptables -w 2 -t filter -N "$CHAIN_BLK" 2>/dev/null
    iptables -w 2 -t filter -F "$CHAIN_BLK"
    iptables -w 2 -t filter -C OUTPUT -j "$CHAIN_BLK" 2>/dev/null || \
        iptables -w 2 -t filter -I OUTPUT 1 -j "$CHAIN_BLK"

    iptables -w 2 -t filter -A "$CHAIN_BLK" \
        -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

    # 首选 DROP
    if iptables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && \
       iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null && \
       iptables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null; then
        _act="DROP"
    else
        # 降级 REJECT
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

    # 校验
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

    # 首选 DROP
    if ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p tcp --dport 853 -j DROP 2>/dev/null && \
       ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 853 -j DROP 2>/dev/null && \
       ip6tables -w 2 -t filter -A "$CHAIN_BLK" -p udp --dport 443 -j DROP 2>/dev/null; then
        _act="DROP"
    else
        # 降级 REJECT
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

    # 校验
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
# 全量重建
# ============================================================================
rebuild_all() {
    log Info "重建规则 (DNS_PORT=$DNS_PORT, block_ipv6_dns=$block_ipv6_dns)" "$LOG_FILE"
    BLOCK4_ACT=""
    BLOCK6_ACT=""
    detect_ipv6

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
    enable|"") first_setup ;;
    disable)   stop_all ;;
    status)    show_status ;;
    *) echo "用法: $0 {enable|disable|status} [DNS_PORT]"; exit 1 ;;
esac