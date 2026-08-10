#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf

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



# ======================== 主服务函数 ========================

stop_service() {
    log Info "================停止代理=================" "${log_dir}/mihomo.log"
    kill_by_name mihomo
    log Info "已停止mihomo内核" "${log_dir}/mihomo.log"
    kill_by_name ruleconverter
    log Info "已停止ruleconverter插件" "${log_dir}/mihomo.log"
    "${module_dir}/scripts/iptables.sh" disable &
}

start_service() {
    local enable_socks="${1:-${enable_socks:-false}}"
    log Info "================开启代理=================" "${log_dir}/mihomo.log"

    # 检查是否已运行
    if is_process_running "mihomo"; then
        stop_service
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