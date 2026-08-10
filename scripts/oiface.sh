#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf

# 功能：开启
enable_mod() {
    log Info "开始开启模块功能" ${log_dir}/oiface.log
    
    # 1. 屏蔽 msm_irqbalance
    for SYSPERFCONFIG in $(ls /system/vendor/bin/msm_irqbalance 2>/dev/null); do
        mkdir -p ${module_dir}${SYSPERFCONFIG%/*}
        touch ${module_dir}$SYSPERFCONFIG
        log Info "已屏蔽 msm_irqbalance: $SYSPERFCONFIG" ${log_dir}/oiface.log
    done
    
    # 2. 锁定 CPU 核心数
    for MAX_CPUS in /sys/devices/system/cpu/cpu*/core_ctl/max_cpus; do
        if [ -e "$MAX_CPUS" ] && [ "$(cat $MAX_CPUS)" != "$(cat ${MAX_CPUS%/*}/min_cpus)" ]; then
            chmod a+w "${MAX_CPUS%/*}/min_cpus"
            echo "$(cat $MAX_CPUS)" > "${MAX_CPUS%/*}/min_cpus"
            chmod a-w "${MAX_CPUS%/*}/min_cpus"
            log Info "已锁定 CPU: ${MAX_CPUS%/*}/min_cpus = $(cat $MAX_CPUS)" ${log_dir}/oiface.log
        fi
    done
    
    # 3. 禁用 oiface
    if [ -n "$(getprop persist.sys.oiface.enable)" ]; then
        setprop persist.sys.oiface.enable 0
        log Info "已禁用 oiface (persist.sys.oiface.enable=0)" ${log_dir}/oiface.log
    fi
    
    log Info "模块开启完成" ${log_dir}/oiface.log
    echo "模块已开启"
}

# 功能：关闭（恢复原状）
disable_mod() {
    log Info "开始关闭模块功能" ${log_dir}/oiface.log
    
    # 1. 恢复 msm_irqbalance
    if [ -f "${module_dir}/system/vendor/bin/msm_irqbalance" ]; then
        rm -rf ${module_dir}/system/vendor/bin/msm_irqbalance
        log Info "已恢复 msm_irqbalance" ${log_dir}/oiface.log
    else
        log Info "msm_irqbalance 未被屏蔽，跳过" ${log_dir}/oiface.log
    fi
    
    # 2. 恢复 CPU 核心数动态调节
    for MAX_CPUS in /sys/devices/system/cpu/cpu*/core_ctl/max_cpus; do
        if [ -e "$MAX_CPUS" ]; then
            CURRENT_MIN=$(cat ${MAX_CPUS%/*}/min_cpus 2>/dev/null)
            CURRENT_MAX=$(cat $MAX_CPUS 2>/dev/null)
            if [ "$CURRENT_MIN" = "$CURRENT_MAX" ]; then
                chmod a+w "${MAX_CPUS%/*}/min_cpus"
                echo "0" > "${MAX_CPUS%/*}/min_cpus"
                chmod a-w "${MAX_CPUS%/*}/min_cpus"
                log Info "已恢复 CPU: ${MAX_CPUS%/*}/min_cpus = 0" ${log_dir}/oiface.log
            fi
        fi
    done
    
    # 3. 恢复 oiface
    if [ "$(getprop persist.sys.oiface.enable)" = "0" ]; then
        setprop persist.sys.oiface.enable 1
        log Info "已恢复 oiface (persist.sys.oiface.enable=1)" ${log_dir}/oiface.log
    else
        log Info "oiface 已是开启状态，跳过" ${log_dir}/oiface.log
    fi
    
    log Info "模块关闭完成" ${log_dir}/oiface.log
    echo "模块已关闭"
}

# 查看状态
status_mod() {
    echo "=== 模块状态 ==="
    echo "msm_irqbalance 屏蔽: $([ -f ${module_dir}/system/vendor/bin/msm_irqbalance ] && echo '开启' || echo '关闭')"
    
    for M in /sys/devices/system/cpu/cpu*/core_ctl/max_cpus; do
        if [ -e "$M" ]; then
            MIN=$(cat ${M%/*}/min_cpus 2>/dev/null)
            MAX=$(cat $M 2>/dev/null)
            if [ "$MIN" = "$MAX" ]; then
                echo "CPU 锁定: 开启 ($MIN = $MAX)"
            else
                echo "CPU 锁定: 关闭 (min=$MIN, max=$MAX)"
            fi
            break
        fi
    done
    
    echo "oiface: $(getprop persist.sys.oiface.enable)"
    echo ""
    echo "最新日志:"
    tail -5 ${log_dir}/oiface.log 2>/dev/null || echo "暂无日志"
}

# 主逻辑
case "$1" in
    enable)
        enable_mod
        ;;
    disable)
        disable_mod
        ;;
    status)
        status_mod
        ;;
    *)
        echo "Usage: $0 {enable|disable|status}"
        echo "  enable  - 开启模块功能"
        echo "  disable - 关闭模块功能（恢复原状）"
        echo "  status  - 查看当前状态"
        exit 1
        ;;
esac