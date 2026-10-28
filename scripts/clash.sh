#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf

# ---------- 变量兜底 ----------
: "${block_ipv6_mihomo:=false}"

app_package(){
    # ==========================================
    # 1. 参数检查 - 全局模式
    # ==========================================
    
    if [ "${4}" != "true" ]; then
        log Info "${2}为全局模式" "${log_dir}/mihomo.log"
        
        # ==========================================
        # 根据类型决定行为
        # ==========================================
        
        if [ "${3}" = "include-package" ]; then
            # ==========================================
            # 全局白名单：获取所有应用包名
            # ==========================================
            
            log Info "全局白名单：获取所有应用包名" "${log_dir}/mihomo.log"
            
            # 使用 pm list packages 获取所有应用包名
            all_packages=$(pm list packages | sed 's/^package://g' | sort)
            
            # 检查是否获取到包名
            if [ -z "${all_packages}" ]; then
                log Error "获取所有应用包名失败" "${log_dir}/mihomo.log"
                return 1
            fi
            
            # 构建 YAML 列表
            uidlist_yaml="["
            first=true
            count=0
            
            for package in ${all_packages}
            do
                # 跳过空包名
                [ -z "${package}" ] && continue
                
                # 构建 YAML 数组
                if [ "${first}" = true ]; then
                    uidlist_yaml="${uidlist_yaml}${package}"
                    first=false
                else
                    uidlist_yaml="${uidlist_yaml}, ${package}"
                fi
                
                count=$((count + 1))
            done
            uidlist_yaml="${uidlist_yaml}]"
            
            log Info "获取到 ${count} 个应用包名" "${log_dir}/mihomo.log"
            
            # 设置所有应用包名
            yamlcli -f "${YAML_FILE}" set "tun.${3}" "${uidlist_yaml}" 2>/dev/null || {
                log Error "设置 ${3} 为所有应用失败" "${log_dir}/mihomo.log"
                return 1
            }
            log Info "已设置 include-package 为所有应用（全局白名单）" "${log_dir}/mihomo.log"
            
            # 删除黑名单（互斥）
            yamlcli -f "${YAML_FILE}" del "tun.exclude-package" 2>/dev/null || true
            log Info "已删除 exclude-package 配置（互斥）" "${log_dir}/mihomo.log"
            
            log Info "全局白名单配置完成 (共添加 ${count} 个应用)" "${log_dir}/mihomo.log"
            
        elif [ "${3}" = "exclude-package" ]; then
            # ==========================================
            # 全局黑名单：设置为空数组（不禁止任何应用）
            # ==========================================
            
            log Info "全局黑名单：设置为空数组（不禁止任何应用）" "${log_dir}/mihomo.log"
            
            # 设置为空数组
            yamlcli -f "${YAML_FILE}" set "tun.${3}" "[]" 2>/dev/null || {
                log Error "设置 ${3} 为空数组失败" "${log_dir}/mihomo.log"
                return 1
            }
            log Info "已设置 exclude-package 为空数组（全局黑名单）" "${log_dir}/mihomo.log"
            
            # 删除白名单（互斥）
            yamlcli -f "${YAML_FILE}" del "tun.include-package" 2>/dev/null || true
            log Info "已删除 include-package 配置（互斥）" "${log_dir}/mihomo.log"
            
            log Info "全局黑名单配置完成（空数组）" "${log_dir}/mihomo.log"
        fi
        
        return 0
    fi
    
    # ==========================================
    # 2. 文件检查（白名单/黑名单模式）
    # ==========================================
    
    # 检查文件是否存在
    if [ ! -f "${1}" ]; then
        log Info "${2}文件不存在: ${1}" "${log_dir}/mihomo.log"
        return 0
    fi
    
    # ==========================================
    # 3. 读取包名列表
    # ==========================================
    
    # 读取内容（过滤注释行和空行）
    list_content=$(cat "${1}" | grep -v '^#' | grep -v '^[[:space:]]*$')
    
    # ==========================================
    # 4. 处理无内容情况 - 设置为空数组
    # ==========================================
    
    if [ -z "${list_content}" ]; then
        log Info "${2}无内容，设置为空数组" "${log_dir}/mihomo.log"
        
        # 设置为空数组
        yamlcli -f "${YAML_FILE}" set "tun.${3}" "[]" 2>/dev/null || {
            log Error "设置 ${3} 为空数组失败" "${log_dir}/mihomo.log"
            return 1
        }
        
        # 互斥处理：删除对应的冲突配置
        if [ "${3}" = "include-package" ]; then
            yamlcli -f "${YAML_FILE}" del "tun.exclude-package" 2>/dev/null || true
            log Info "已删除旧的黑名单配置" "${log_dir}/mihomo.log"
        elif [ "${3}" = "exclude-package" ]; then
            yamlcli -f "${YAML_FILE}" del "tun.include-package" 2>/dev/null || true
            log Info "已删除旧的白名单配置" "${log_dir}/mihomo.log"
        fi
        
        log Info "${2}已设置为空数组" "${log_dir}/mihomo.log"
        return 0
    fi
    
    # ==========================================
    # 5. 有内容时构建 YAML 列表
    # ==========================================
    
    log Info "添加${2} App:" "${log_dir}/mihomo.log"
    
    uidlist_yaml="["
    first=true
    count=0
    
    for package in ${list_content}
    do
        # 去除 ,no-rule 等后缀
        pkg_name=$(echo "${package}" | sed 's/,.*//g')
        
        # 跳过空包名
        [ -z "${pkg_name}" ] && continue
        
        log Info "  ${pkg_name}" "${log_dir}/mihomo.log"
        
        # 构建 YAML 数组
        if [ "${first}" = true ]; then
            uidlist_yaml="${uidlist_yaml}${pkg_name}"
            first=false
        else
            uidlist_yaml="${uidlist_yaml}, ${pkg_name}"
        fi
        
        count=$((count + 1))
    done
    uidlist_yaml="${uidlist_yaml}]"
    
    # ==========================================
    # 6. 构建字段路径
    # ==========================================
    
    pkg_field="tun.${3}"
    
    # ==========================================
    # 7. 使用 yamlcli 设置配置
    # ==========================================
    
    log Info "执行: yamlcli -f ${YAML_FILE} set ${pkg_field} \"${uidlist_yaml}\"" "${log_dir}/mihomo.log"
    
    # 设置包名列表
    yamlcli -f "${YAML_FILE}" set "${pkg_field}" "${uidlist_yaml}" 2>/dev/null || {
        log Error "设置 ${3} 失败" "${log_dir}/mihomo.log"
        return 1
    }
    
    # ==========================================
    # 8. 删除冲突配置（确保互斥）
    # ==========================================
    
    if [ "${3}" = "include-package" ]; then
        # 添加白名单时，删除黑名单
        yamlcli -f "${YAML_FILE}" del "tun.exclude-package" 2>/dev/null || true
        log Info "已删除旧的黑名单配置" "${log_dir}/mihomo.log"
    elif [ "${3}" = "exclude-package" ]; then
        # 添加黑名单时，删除白名单
        yamlcli -f "${YAML_FILE}" del "tun.include-package" 2>/dev/null || true
        log Info "已删除旧的白名单配置" "${log_dir}/mihomo.log"
    fi
    
    # ==========================================
    # 9. 完成
    # ==========================================
    
    log Info "${2}配置完成 (共添加 ${count} 个包名)" "${log_dir}/mihomo.log"
    return 0
}


# ============================================================================
# IPv6 可用性检测（参考 dns.sh 的四层探测思路）
#
# 分层判断：
#   1) 栈状态：/proc/sys/net/ipv6/conf/all/disable_ipv6
#   2) ip6tables filter 表可用性（仅作日志参考）
#   3) ip6tables nat + REDIRECT 实弹测试（仅作日志参考）
#   4) 是否有全局 IPv6 地址（关键判定）
#
# 综合判定：栈正常 AND 有全局地址 → 可用
# 输出变量：
#   IPV6_STACK_OK / IPV6_HAS_ADDR / IPV6_CMD_OK / IPV6_NAT_OK / IPV6_AVAILABLE
# ============================================================================
detect_ipv6_for_mihomo() {
    IPV6_STACK_OK=false
    IPV6_HAS_ADDR=false
    IPV6_CMD_OK=false
    IPV6_NAT_OK=false
    IPV6_AVAILABLE=false

    # 第 1 层：栈状态
    _dis=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
    [ "$_dis" != "1" ] && IPV6_STACK_OK=true

    # 第 2/3 层：ip6tables 能力（仅作日志参考，不参与最终判定）
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -w 2 -t filter -L >/dev/null 2>&1 && IPV6_CMD_OK=true
        if ip6tables -w 2 -t nat -L >/dev/null 2>&1; then
            if ip6tables -w 2 -t nat -A PREROUTING -p tcp --dport 65534 \
                    -j REDIRECT --to-port 65534 >/dev/null 2>&1; then
                IPV6_NAT_OK=true
                ip6tables -w 2 -t nat -D PREROUTING -p tcp --dport 65534 \
                    -j REDIRECT --to-port 65534 2>/dev/null
            fi
        fi
    fi

    # 第 4 层：是否有全局 IPv6 地址（排除 ::1 与 fe80::/10）
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' \
            && IPV6_HAS_ADDR=true
    elif [ -s /proc/net/if_inet6 ]; then
        while read -r _addr _rest; do
            case "$_addr" in
                00000000000000000000000000000001) continue ;;
                fe8*|fe9*|fea*|feb*) continue ;;
                *) IPV6_HAS_ADDR=true; break ;;
            esac
        done < /proc/net/if_inet6
    fi

    # 综合判定
    if [ "$IPV6_STACK_OK" = "true" ] && [ "$IPV6_HAS_ADDR" = "true" ]; then
        IPV6_AVAILABLE=true
        log Info "IPv6 可用（栈正常 + 有全局地址；filter=$IPV6_CMD_OK nat=$IPV6_NAT_OK）" \
            "${log_dir}/mihomo.log"
    else
        _r=""
        [ "$IPV6_STACK_OK" != "true" ] && _r="${_r}[disable_ipv6=1]"
        [ "$IPV6_HAS_ADDR" != "true" ] && _r="${_r}[无全局IPv6地址]"
        log Warn "IPv6 不可用 ${_r}" "${log_dir}/mihomo.log"
    fi

    [ "$IPV6_AVAILABLE" = "true" ]
}


# ============================================================================
# 按检测结果同步 mihomo 的 ipv6 / dns.ipv6
#
#   参数 $1: true=恢复原值  false=强制关闭
#
# 原值持久化到 fun.conf：
#   mihomo_orig_ipv6
#   mihomo_orig_dns_ipv6
#   字段原不存在时记 __unset__，恢复时用 del 删除，不污染用户配置
# ============================================================================
sync_mihomo_ipv6() {
    _want="$1"
    _conf="${module_dir}/fun.conf"

    _conf_write() {
        _k="$1"; _v="$2"
        [ -f "$_conf" ] || return 0
        [ -n "$(tail -c 1 "$_conf" 2>/dev/null)" ] && echo "" >> "$_conf"
        sed -i "/^${_k}=/d" "$_conf" 2>/dev/null
        printf '%s=%s\n' "$_k" "$_v" >> "$_conf"
    }
    _conf_del() {
        [ -f "$_conf" ] && sed -i "/^$1=/d" "$_conf" 2>/dev/null
    }

    if [ "$_want" = "false" ]; then
        # ---- 首次记录原值（只记一次，防止把上次的 false 误当原值）----
        if [ -z "${mihomo_orig_ipv6:-}" ]; then
            _o_ipv6=$(yamlcli -f "${YAML_FILE}" get "ipv6" 2>/dev/null)
            [ -z "$_o_ipv6" ] && _o_ipv6="__unset__"
            _o_dns=$(yamlcli -f "${YAML_FILE}" get "dns.ipv6" 2>/dev/null)
            [ -z "$_o_dns" ] && _o_dns="__unset__"

            _conf_write mihomo_orig_ipv6     "$_o_ipv6"
            _conf_write mihomo_orig_dns_ipv6 "$_o_dns"
            mihomo_orig_ipv6="$_o_ipv6"
            mihomo_orig_dns_ipv6="$_o_dns"
            log Info "记录原值 ipv6=${_o_ipv6} dns.ipv6=${_o_dns}" "${log_dir}/mihomo.log"
        fi
        # ---- 强制关闭 ----
        yamlcli -f "${YAML_FILE}" set "ipv6"     false 2>/dev/null
        yamlcli -f "${YAML_FILE}" set "dns.ipv6" false 2>/dev/null
        log Info "已强制关闭 ipv6 / dns.ipv6" "${log_dir}/mihomo.log"

    else
        # ---- 恢复原值 ----
        if [ -n "${mihomo_orig_ipv6:-}" ]; then
            if [ "${mihomo_orig_ipv6}" = "__unset__" ]; then
                yamlcli -f "${YAML_FILE}" del "ipv6" 2>/dev/null
            else
                yamlcli -f "${YAML_FILE}" set "ipv6" "${mihomo_orig_ipv6}" 2>/dev/null
            fi

            case "${mihomo_orig_dns_ipv6:-}" in
                ""|__unset__)
                    yamlcli -f "${YAML_FILE}" del "dns.ipv6" 2>/dev/null
                    ;;
                *)
                    yamlcli -f "${YAML_FILE}" set "dns.ipv6" "${mihomo_orig_dns_ipv6}" 2>/dev/null
                    ;;
            esac

            log Info "已恢复 ipv6=${mihomo_orig_ipv6} dns.ipv6=${mihomo_orig_dns_ipv6:-未记录}" \
                "${log_dir}/mihomo.log"

            _conf_del mihomo_orig_ipv6
            _conf_del mihomo_orig_dns_ipv6
            mihomo_orig_ipv6=""
            mihomo_orig_dns_ipv6=""
        fi
    fi
}


# ======================== 主服务函数 ========================

# 参数 $1: 传 "true" 表示跳过 IPv6 配置恢复
#          （start_service 重启内核时用，避免连续 enable 抖动）
stop_service() {
    local _skip_restore="${1:-false}"

    log Info "================停止代理=================" "${log_dir}/mihomo.log"
    kill_by_name mihomo
    log Info "已停止mihomo内核" "${log_dir}/mihomo.log"
    kill_by_name ruleconverter
    log Info "已停止ruleconverter插件" "${log_dir}/mihomo.log"

    # 恢复 ipv6 / dns.ipv6 用户原值（重启内核时跳过）
    if [ "$_skip_restore" != "true" ]; then
        sync_mihomo_ipv6 true
    fi

    "${module_dir}/scripts/iptables.sh" disable &
}

start_service() {
    local enable_socks="${1:-${enable_socks:-false}}"
    log Info "================开启代理=================" "${log_dir}/mihomo.log"

    # 检查是否已运行（重启时跳过 IPv6 配置恢复，交给后面重新检测）
    if is_process_running "mihomo"; then
        stop_service "true"
    fi
    
    if [ "${enable_socks}" = "true" ];then
        if [ "${MIHOMO_AUTOROUTE}" = "true" ];then
            set_config "enable_tun" "true"
            yamlcli -f ${YAML_FILE} set "tun.enable" false
        else
            set_config "enable_tun" "false"
        fi
        log Info "SOCKS模式" "${log_dir}/mihomo.log"
    else
        if [ -n "${enable_tun:-}" ]; then
            yamlcli -f ${YAML_FILE} set "tun.enable" ${enable_tun}
            log Info "恢复 TUN 状态: ${enable_tun}" "${log_dir}/mihomo.log"
        fi
    fi
     
    
    if [ ${mode} = "global" ]; then
            log Info "使用全局模式" "${log_dir}/mihomo.log"
            app_package "${BLACK_LIST_FILE}" "黑名单" "exclude-package" "false"
        elif [ ${mode} = "blacklist" ]; then
            log Info "使用黑名单模式" "${log_dir}/mihomo.log"
            app_package "${BLACK_LIST_FILE}" "黑名单" "exclude-package" "true"
        elif [ ${mode} = "whitelist" ]; then
            log Info "使用白名单模式" "${log_dir}/mihomo.log"
            app_package "${WHITE_LIST_FILE}" "白名单" "include-package" "true"
    fi
    
    # ---------- IPv6 同步（受 block_ipv6_mihomo 控制） ----------
    # block_ipv6_mihomo=true  → 强制关闭 mihomo 的 ipv6/dns.ipv6
    # block_ipv6_mihomo=false → 按系统 IPv6 可用性自动判断
    if [ "${block_ipv6_mihomo}" = "true" ]; then
        log Info "block_ipv6_mihomo=true → 强制关闭 mihomo IPv6 配置" "${log_dir}/mihomo.log"
        sync_mihomo_ipv6 false
    else
        if detect_ipv6_for_mihomo; then
            sync_mihomo_ipv6 true
        else
            sync_mihomo_ipv6 false
        fi
    fi
    
    # ---------- 测试配置 ----------
    if ! kernel_error=$("${module_dir}/bin/mihomo" \
        -d "${module_dir}/mihomoData" \
        -t -f "$YAML_FILE" 2>&1); then
        log Error "配置有误，启动失败" "${log_dir}/mihomo.log"
        log Error "$kernel_error" "${log_dir}/mihomo.log"
        return 1
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
    
    if [ "${enable_socks}" = "true" ];then
        "${module_dir}/scripts/iptables.sh" disable &
        return 0
    else
        "${module_dir}/scripts/iptables.sh" enable &
        return 0
    fi
}



case "$1" in
    enable)
        start_service "$2"
        ;;
    disable)
        stop_service
        ;;
    *)
        echo "Usage: $0 {enable|disable}"
        exit 1
        ;;
esac