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
MIHOMO_CONF="${module_dir}/conf/mihomo.yaml"

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
# 核心逻辑：处理 DNS 重定向与 IPv6 联动
# ==========================================
handle_dns_redir() {
    ACTION="$1"
    PORT="$2"

    # 【防抖锁机制】 ---------------- 开始 ----------------
    LOCK_DIR="/data/local/tmp/linlin_ipv6_lock"
    
    if [ "$ACTION" = "ipv6_on" ] || [ "$ACTION" = "ipv6_off" ]; then
        if [ -d "$LOCK_DIR" ]; then
            CURRENT_OP=$(cat "$LOCK_DIR/current" 2>/dev/null)
            if [ "$CURRENT_OP" = "$ACTION" ]; then
                echo "正在执行相同的操作 ($ACTION)，忽略请求"
                return 0
            fi
            echo "$ACTION" > "$LOCK_DIR/next"
            echo "排队中：等待当前操作结束后执行 $ACTION"
            return 0
        fi

        mkdir -p "$LOCK_DIR"
        echo "$ACTION" > "$LOCK_DIR/current"
        rm -f "$LOCK_DIR/next"
    fi
    # 【防抖锁机制】 ---------------- 结束 ----------------

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

    # 处理 IPv6 全局联动开关
    if [ "$ACTION" = "ipv6_on" ] || [ "$ACTION" = "ipv6_off" ]; then
        local val="false"
        [ "$ACTION" = "ipv6_on" ] && val="true"
        
        # 1. 写入 config.conf 的 block_ipv6 状态
        if grep -q "^block_ipv6=" "$CONFIG_CONF"; then
            sed -i "s/^block_ipv6=.*/block_ipv6=\"$val\"/" "$CONFIG_CONF"
        else
            echo "block_ipv6=\"$val\"" >> "$CONFIG_CONF"
        fi

        # 2. 同步 mihomo.yaml
        local mihomo_ipv6="true"
        [ "$val" = "true" ] && mihomo_ipv6="false"
        yamlcli -f "$MIHOMO_CONF" set "ipv6" "$mihomo_ipv6" >/dev/null 2>&1
        yamlcli -f "$MIHOMO_CONF" set "dns.ipv6" "$mihomo_ipv6" >/dev/null 2>&1

        # 3. 同步系统栈
        if [ "$val" = "true" ]; then
            echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
            echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
            sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
        else
            echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
            echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
        fi

        # 4. 热重载 dns 规则
        sh "${module_dir}/scripts/dns.sh" enable >/dev/null 2>&1
        
        # 5. 【修改为硬重启】mihomo 重启
        if pgrep -f "${module_dir}/bin/mihomo" >/dev/null 2>&1; then
            echo "正在硬重启 mihomo..."
            nohup sh -c "
                nohup sh '${module_dir}/scripts/clash.sh' disable >/dev/null 2>&1 < /dev/null
                sleep 1
                nohup sh '${module_dir}/scripts/clash.sh' enable >/dev/null 2>&1 < /dev/null
            " &
        fi

        # 6. 重启 AdGuardHome（加入回环口等待探测）
        if pgrep -f "${module_dir}/bin/AdGuardHome" >/dev/null 2>&1; then
            echo "重启 AdGuardHome 应用最新的监听配置"
            sh "${module_dir}/scripts/control.sh" adguardhome stop >/dev/null 2>&1
            
            if [ "$val" = "false" ]; then
                echo "等待系统 IPv6 回环口 (::1) 就绪..."
                COUNT=0
                while [ $COUNT -lt 20 ]; do
                    if ip -6 addr show lo | grep -q "::1"; then break; fi
                    sleep 0.5
                    COUNT=$((COUNT + 1))
                done
                sleep 1
            fi
            
            sh "${module_dir}/scripts/control.sh" adguardhome start >/dev/null 2>&1
        fi
        
        # 【防抖锁机制】检查是否有排队的新任务 ----------------
        if [ -d "$LOCK_DIR" ]; then
            if [ -f "$LOCK_DIR/next" ]; then
                NEXT_ACTION=$(cat "$LOCK_DIR/next")
                rm -f "$LOCK_DIR/next"
                rm -rf "$LOCK_DIR"
                echo "检测到中断，立即执行最新指令: $NEXT_ACTION"
                sh "$0" dns-redir "$NEXT_ACTION"
                return 0
            else
                rm -rf "$LOCK_DIR"
            fi
        fi
        # ----------------------------------------------------
        
        return 0
    fi

    # 普通 DNS 重定向开关
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
# 核心逻辑：mihomo 代理模式与过滤模式切换
# ==========================================
handle_mihomo_mode() {
    ACTION="$1"
    API_PORT=$(yamlcli -f "$MIHOMO_CONF" get 'external-controller' 2>/dev/null | sed 's/.*://')
    API_SECRET=$(yamlcli -f "$MIHOMO_CONF" get 'secret' 2>/dev/null | tr -d '"')
    API_PORT="${API_PORT:-9090}"

    # ==========================================
    # 1. check —— 读 mihomo 运行时模式 (rule/global/direct)
    # ==========================================
    if [ "$ACTION" = "check" ]; then
        if [ -n "$API_SECRET" ]; then
            RES=$(curl -s -m 2 -H "Authorization: Bearer $API_SECRET" \
                  "http://127.0.0.1:${API_PORT}/configs" 2>/dev/null)
        else
            RES=$(curl -s -m 2 "http://127.0.0.1:${API_PORT}/configs" 2>/dev/null)
        fi
        MODE=$(echo "$RES" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
        echo "${MODE:-unknown}"
        return 0
    fi

    # ==========================================
    # 2. getfilter —— 读 config.conf 持久化过滤模式
    # ==========================================
    if [ "$ACTION" = "getfilter" ]; then
        FILTER=$(grep "^mode=" "$CONFIG_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d '"')
        echo "${FILTER:-global}"
        return 0
    fi

    # ==========================================
    # 3. 代理模式:rule / global / direct —— API 热切换,不落盘
    # ==========================================
    if [ "$ACTION" = "rule" ] || [ "$ACTION" = "global" ] || [ "$ACTION" = "direct" ]; then
        if [ -n "$API_SECRET" ]; then
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 \
                -X PATCH \
                -H "Authorization: Bearer $API_SECRET" \
                -H "Content-Type: application/json" \
                -d "{\"mode\":\"$ACTION\"}" \
                "http://127.0.0.1:${API_PORT}/configs" 2>/dev/null)
        else
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 2 \
                -X PATCH \
                -H "Content-Type: application/json" \
                -d "{\"mode\":\"$ACTION\"}" \
                "http://127.0.0.1:${API_PORT}/configs" 2>/dev/null)
        fi

        if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
            echo "代理模式已切换为 $ACTION"
            return 0
        else
            echo "切换失败: HTTP ${HTTP_CODE:-000} (mihomo 可能未运行或密钥错误)" >&2
            return 1
        fi
    fi

    # ==========================================
    # 4. 过滤模式:filter_blacklist / filter_whitelist / filter_global
    #    —— 落盘 config.conf + 硬重启 mihomo
    # ==========================================
    case "$ACTION" in
        filter_blacklist|filter_whitelist|filter_global)
            filter_val="${ACTION#filter_}"

            # 4.1 落盘 mode
            if grep -q "^mode=" "$CONFIG_CONF" 2>/dev/null; then
                sed -i "s/^mode=.*/mode=\"$filter_val\"/" "$CONFIG_CONF"
            else
                echo "mode=\"$filter_val\"" >> "$CONFIG_CONF"
            fi
            echo "过滤模式已修改为 $filter_val"

            # 4.2 是否需要重启
            if ! pgrep -f "${module_dir}/bin/mihomo" >/dev/null 2>&1; then
                echo "mihomo 未运行，配置已保存，将于下次启动生效"
                return 0
            fi

            echo "正在重启 mihomo 以应用新过滤模式..."
            nohup sh -c "
                # 停止
                nohup sh '${module_dir}/scripts/clash.sh' disable >/dev/null 2>&1 < /dev/null
                # 轮询等待旧进程退出，最多 10 秒
                i=0
                while [ \$i -lt 10 ] && pgrep -f '${module_dir}/bin/mihomo' >/dev/null 2>&1; do
                    sleep 1
                    i=\$((i+1))
                done
                # 启动
                nohup sh '${module_dir}/scripts/clash.sh' enable >/dev/null 2>&1 < /dev/null
            " >/dev/null 2>&1 < /dev/null &

            echo "重启任务已在后台执行"
            return 0
            ;;

        # ==========================================
        # 5. 未知动作
        # ==========================================
        *)
            echo "未知 mihomo-mode 动作: $ACTION" >&2
            echo "支持: check | getfilter | rule | global | direct | filter_blacklist | filter_whitelist | filter_global" >&2
            return 1
            ;;
    esac
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
        calc_all_fd
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