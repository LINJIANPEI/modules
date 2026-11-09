#!/system/bin/sh
# 用法: control.sh <服务名> <start|stop>
# 服务名: mihomo / adguardhome / smartdns / oxidns / smartdns-proxy / dns-redir / mihomo-mode

# 引入全局配置
source /data/adb/modules/Linlin/fun.conf

SVC="$1"
ACTION="$2"
ARG3="$3"

[ -z "$SVC" ] || [ -z "$ACTION" ] && { echo "用法: control.sh <服务名> <start|stop>" >&2; exit 1; }

CONF_FILE="${module_dir}/conf/smartdns.conf"
FUN_CONF="${module_dir}/fun.conf"
CONFIG_CONF="${module_dir}/config.conf"

# ==========================================
# 核心功能：极其稳妥地重启 SmartDNS
# ==========================================
restart_smartdns() {
    kill_by_name "smartdns"

    calc_all_fd

    nohup sh -c "
        ulimit -n $FD_SMARTDNS
        cd ${module_dir}/smartdnsData
        busybox setuidgid ${uid}:${gid} ${module_dir}/bin/smartdns -c $CONF_FILE -f
    " > "${log_dir}/smartdns.log" 2>&1 < /dev/null &
    
    sleep 1
    
    if pgrep -f "${module_dir}/bin/smartdns" >/dev/null 2>&1; then
        echo "smartdns 已成功启动"
    else
        echo "smartdns 启动失败！请检查 ${log_dir}/smartdns.log"
    fi
}

# ==========================================
# 核心逻辑：处理 smartdns 代理开关
# ==========================================
handle_smartdns_proxy() {
    IS_ON="$1"
    
    # 状态判断：如果 proxy-server 被注释了，说明代理关闭
    if grep -qE "^[[:space:]]*#.*proxy-server" "$CONF_FILE"; then
        CURRENT_STATE="off"
    else
        CURRENT_STATE="on"
    fi

    if [ "$IS_ON" = "check" ]; then
        echo "$CURRENT_STATE"
        return 0
    fi

    if [ "$IS_ON" = "on" ]; then
        # 开启代理
        awk '
        {
            if ($0 ~ /^[ \t]*#[ \t]*proxy-server/) {
                sub(/^[ \t]*#[ \t]*/, "")
            }
            if ($0 ~ /-proxy[ \t]*socks5/ || $0 ~ /#[ \t]*-proxy[ \t]*socks5/) {
                sub(/#[ \t]*-proxy[ \t]*socks5/, "")
                if ($0 ~ /-proxy[ \t]*socks5/ || $0 ~ /server-.*office/) {
                    if ($0 !~ /-proxy[ \t]*socks5$/) {
                        sub(/[ \t]+$/, "")
                        $0 = $0 " -proxy socks5"
                    }
                }
            }
            print $0
        }' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        echo "smartdns 代理已开启"
    else
        # 关闭代理
        awk '
        {
            if ($0 ~ /proxy-server/ && $0 !~ /^[ \t]*#/) {
                $0 = "# " $0
            }
            if ($0 ~ /-proxy[ \t]*socks5/ && $0 !~ /^[ \t]*#/) {
                if ($0 ~ /-proxy[ \t]*socks5[ \t]*$/) {
                    sub(/-proxy[ \t]*socks5[ \t]*$/, "# -proxy socks5")
                } else {
                    sub(/[ \t]*-proxy[ \t]*socks5/, "")
                    sub(/[ \t]+$/, "")
                    $0 = $0 " # -proxy socks5"
                }
            }
            print $0
        }' "$CONF_FILE" > "${CONF_FILE}.tmp" && mv "${CONF_FILE}.tmp" "$CONF_FILE"
        echo "smartdns 代理已关闭"
    fi

    restart_smartdns
}

# ==========================================
# 核心逻辑：处理 DNS 重定向
# ==========================================
handle_dns_redir() {
    ACTION="$1"
    PORT="$2"

    if [ "$ACTION" = "getport" ]; then
        source "$CONFIG_CONF" 2>/dev/null
        source "$FUN_CONF" 2>/dev/null
        SHOW_PORT="${dns_state_port:-${redir_port:-53}}"
        echo "$SHOW_PORT"
        return 0
    fi

    if [ "$ACTION" = "check" ]; then
        if grep -q "^dns_state_port=" "$FUN_CONF" || grep -q "^enable_iptables=\"true\"" "$CONFIG_CONF"; then
            echo "on"
        else
            echo "off"
        fi
        return 0
    fi

    # 处理 IPv6 开关
    if [ "$ACTION" = "ipv6_on" ] || [ "$ACTION" = "ipv6_off" ]; then
        local val="false"
        [ "$ACTION" = "ipv6_on" ] && val="true"
        
        # 修改 config.conf 里的 block_ipv6_dns
        if grep -q "^block_ipv6_dns=" "$CONFIG_CONF"; then
            sed -i "s/^block_ipv6_dns=.*/block_ipv6_dns=\"$val\"/" "$CONFIG_CONF"
        else
            echo "block_ipv6_dns=\"$val\"" >> "$CONFIG_CONF"
        fi
        
        # 重启重定向使配置生效
        sh "${module_dir}/scripts/dns.sh" disable >/dev/null 2>&1
        sleep 1
        sh "${module_dir}/scripts/dns.sh" enable >/dev/null 2>&1
        echo "IPv6 DNS 封锁已设置为 $val"
        return 0
    fi

    if [ "$ACTION" = "on" ]; then
        if [ -n "$PORT" ]; then
            sh "${module_dir}/scripts/dns.sh" enable "$PORT" >/dev/null 2>&1
        else
            sh "${module_dir}/scripts/dns.sh" enable >/dev/null 2>&1
        fi
        echo "DNS 重定向已开启"
    elif [ "$ACTION" = "off" ]; then
        sh "${module_dir}/scripts/dns.sh" disable >/dev/null 2>&1
        echo "DNS 重定向已关闭"
    elif [ "$ACTION" = "setport" ]; then
        if [ -z "$PORT" ]; then echo "缺少端口参数" >&2; exit 1; fi
        if grep -q "^redir_port=" "$CONFIG_CONF"; then
            sed -i "s/^redir_port=.*/redir_port=$PORT/" "$CONFIG_CONF"
        else
            echo "redir_port=$PORT" >> "$CONFIG_CONF"
        fi
        if grep -q "^dns_state_port=" "$FUN_CONF"; then
            sed -i "s/^dns_state_port=.*/dns_state_port=$PORT/" "$FUN_CONF"
        else
            echo "dns_state_port=$PORT" >> "$FUN_CONF"
        fi
        sh "${module_dir}/scripts/dns.sh" disable >/dev/null 2>&1
        sleep 1
        sh "${module_dir}/scripts/dns.sh" enable "$PORT" >/dev/null 2>&1
        echo "重定向端口已修改为 $PORT"
    fi
}

# ==========================================
# 核心逻辑：mihomo 模式切换
# ==========================================
handle_mihomo_mode() {
    ACTION="$1"
    API_PORT=$(yamlcli -f "${module_dir}/conf/mihomo.yaml" get 'external-controller' 2>/dev/null | sed 's/.*://')
    API_SECRET=$(yamlcli -f "${module_dir}/conf/mihomo.yaml" get 'secret' 2>/dev/null | tr -d '"')
    
    if [ "$ACTION" = "check" ]; then
        RES=$(curl -s -m 2 -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:${API_PORT:-9090}/configs")
        MODE=$(echo "$RES" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
        echo "${MODE:-unknown}"
    else
        curl -s -X PATCH -m 2 -H "Authorization: Bearer $API_SECRET" -d "{\"mode\":\"$ACTION\"}" "http://127.0.0.1:${API_PORT:-9090}/configs" >/dev/null 2>&1
        echo "模式已切换为 $ACTION"
    fi
}

# ==========================================
# 拦截前端发来的子功能请求
# ==========================================
if [ "$SVC" = "smartdns-proxy" ]; then
    handle_smartdns_proxy "$ACTION"
    exit 0
fi

if [ "$SVC" = "dns-redir" ]; then
    handle_dns_redir "$ACTION" "$ARG3"
    exit 0
fi

if [ "$SVC" = "mihomo-mode" ]; then
    handle_mihomo_mode "$ACTION"
    exit 0
fi

# ==========================================
# 主控制路由
# ==========================================
case "$ACTION" in
    start)
        case "$SVC" in
            mihomo)
                nohup sh "${module_dir}/scripts/clash.sh" enable >/dev/null 2>&1 < /dev/null &
                ;;
            adguardhome)
                kill_by_name "AdGuardHome"
                kill_by_name "AghReport"
                nohup sh -c "
                    ulimit -n $FD_ADGUARD
                    cd ${module_dir}/adguardHomeData
                    busybox setuidgid ${uid}:${gid} ${module_dir}/bin/AdGuardHome \
                        -c ${module_dir}/conf/AdGuardHome.yaml \
                        -w ${module_dir}/adguardHomeData \
                        --no-check-update
                " > "${log_dir}/AdGuardHome.log" 2>&1 < /dev/null &
                
                nohup sh -c "
                    busybox setuidgid ${uid}:${gid} ${module_dir}/bin/AghReport
                " >/dev/null 2>&1 < /dev/null &
                ;;
            smartdns)
                handle_smartdns_proxy "on"
                ;;
            oxidns)
                kill_by_name "oxidns"
                nohup sh -c "
                    ulimit -n $FD_OXIDNS
                    cd ${module_dir}/oxidnsData
                    busybox setuidgid ${uid}:${gid} ${module_dir}/bin/oxidns \
                        start \
                        -d ${module_dir}/oxidnsData \
                        -c ${module_dir}/conf/oxidns.yaml
                " > "${log_dir}/oxidns.log" 2>&1 < /dev/null &
                ;;
            *)
                echo "未知服务" >&2; exit 1 ;;
        esac
        
        if [ "$SVC" = "mihomo" ]; then
            handle_smartdns_proxy "on"
        fi
        ;;

    stop)
        case "$SVC" in
            mihomo)
                nohup sh "${module_dir}/scripts/clash.sh" disable >/dev/null 2>&1 < /dev/null &
                ;;
            adguardhome)
                kill_by_name "AdGuardHome"
                kill_by_name "AghReport"
                ;;
            smartdns)
                kill_by_name "smartdns"
                ;;
            oxidns)
                kill_by_name "oxidns"
                ;;
            *)
                echo "未知服务: $SVC" >&2; exit 1 ;;
        esac
        
        if [ "$SVC" = "mihomo" ]; then
            handle_smartdns_proxy "off"
        fi
        ;;
        
    *)
        echo "未知操作: $ACTION" >&2; exit 1 ;;
esac