#!/system/bin/sh
# -------------------- 引入配置 --------------------

source /data/adb/modules/Linlin/fun.conf


# -------------------- 等待系统就绪 --------------------
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

#尝试修复开机不自动执行
cd "${0%/*}"
chmod -R a+x "${0%/*}/bin" "${0%/*}/scripts" 2>/dev/null
# -------------------- 检查hosts模块 --------------------
found_hosts=false
for module in /data/adb/modules/*; do
  [ -d "${module}" ] && [ -f "${module}/system/etc/hosts" ] && {
    found_hosts=true
    touch "${module}/remove"
  }
done

if [ "$found_hosts" = true ]; then
    MSG="检测到hosts模块，模块已停止运行"
    DESC="⚠️ 模块已禁用 - 检测到hosts模块"
    set_module_prop ${DESC}
    log "Error" "${MSG}" "${log_dir}/run.log"
    exit 1
fi

# -------------------- 创建文件夹 --------------------
if [ ! -d ${log_dir} ]; then
    mkdir -p ${log_dir}
fi
if [ ! -d ${module_dir}/cache ]; then
    mkdir -p ${module_dir}/cache
fi


# -------------------- 清理log --------------------
clear_log "${log_dir}/run.log" "${log_dir}/AppOpt.log" "${log_dir}/AdGuardHome.log" "${log_dir}/oxidns.log" "${log_dir}/smartdns.log" "${log_dir}/iptables.log" "${log_dir}/mihomoRun.log" "${log_dir}/ruleconverter.log" "${log_dir}/oiface.log"


# -------------------- FD配置 --------------------


calc_all_fd

log_msg="FD分配 ->"
[ "${enable_AppOpt}" = "true" ] && log_msg="$log_msg AppOpt:$FD_APPOPT"
[ "${enable_adguardhome}" = "true" ] && log_msg="$log_msg AGH:$FD_ADGUARD"
[ "${enable_oxidns}" = "true" ] && log_msg="$log_msg Mos:$FD_OXIDNS"
[ "${enable_mihomo}" = "true" ] && log_msg="$log_msg Mihomo:$FD_MIHOMO"
[ "${enable_smartdns}" = "true" ] && log_msg="$log_msg Smart:$FD_SMARTDNS"
# RESERVED 通常总是输出
log_msg="${log_msg} Reserved:${RESERVED}"
log Info "${log_msg}" ${log_dir}/run.log


# mihomo
if [ "${enable_mihomo}" = "true" ]; then
    kill_by_name "mihomo"
    kill_by_name "ruleconverter"
    (
    ulimit -n "$FD_MIHOMO"
    nohup ${module_dir}/scripts/clash.sh "enable" & > "${log_dir}/mihomo.log" 2>&1 &
    ) &
fi

# AppOpt
if [ "${enable_AppOpt}" = "true" ]; then
    kill_by_name "AppOpt"
    (
    ulimit -n "$FD_APPOPT"
    nohup "${module_dir}/bin/AppOpt" \
        -c "${module_dir}/conf/applist.prop" \
        >"${log_dir}/AppOpt.log" 2>&1 &
    ) &
fi

# AdGuardHome
if [ "${enable_adguardhome}" = "true" ]; then
    kill_by_name "AdGuardHome"
    (
    ulimit -n "$FD_ADGUARD"
    nohup busybox setuidgid ${uid}:${gid} \
        "${module_dir}/bin/AdGuardHome" \
        -c "${module_dir}/conf/AdGuardHome.yaml" \
        -w "${module_dir}/adguardHomeData" \
        --no-check-update \
        >"${log_dir}/AdGuardHome.log" 2>&1 &
    ) &
fi


# oxidns
if [ "${enable_oxidns}" = "true" ]; then
    kill_by_name "oxidns"
    (
    ulimit -n "$FD_OXIDNS"
    nohup busybox setuidgid ${uid}:${gid} \
        "${module_dir}/bin/oxidns" \
        start \
        -d "${module_dir}/oxidnsData" \
        -c "${module_dir}/conf/oxidns.yaml" \
        >"${log_dir}/oxidns.log" 2>&1 &
    ) &
fi

# smartdns
if [ "${enable_smartdns}" = "true" ]; then
    kill_by_name "smartdns"
    (
    ulimit -n "$FD_SMARTDNS"
    nohup busybox setuidgid ${uid}:${gid} \
        "${module_dir}/bin/smartdns" \
        -c "${module_dir}/conf/smartdns.conf" \
        -f \
       >"${log_dir}/smartdns.log" 2>&1 &
    ) &
fi

# -------------------- 其他脚本 --------------------

processes=""
[ "${enable_AppOpt}" = "true" ] && processes="${processes} AppOpt"
[ "${enable_adguardhome}" = "true" ] && processes="${processes} AdGuardHome"
[ "${enable_oxidns}" = "true" ] && processes="${processes} oxidns"
[ "${enable_smartdns}" = "true" ] && processes="${processes} smartdns"
[ "${enable_mihomo}" = "true" ] && processes="${processes} mihomo"

started_procs=$(parallel_wait_all 120 $processes)

if [ $? -eq 0 ]; then

    check_fd ${processes}
    
    # -------------------- 开启重定向dns --------------------
    until netstat -tunlp | grep ${redir_port}; do
      sleep 1
    done
    if [ "${enable_iptables}" = "true" ]; then
        "${module_dir}/scripts/iptables.sh" enable &
    fi
    "${module_dir}/scripts/clearLog.sh" &
    "${module_dir}/scripts/dns.sh" &
    if [ "${enable_oiface}" = "true" ]; then    
      "${module_dir}/scripts/oiface.sh" enable &
    else
      "${module_dir}/scripts/oiface.sh" disable &
    fi 
else
    ${module_dir}/uninstall.sh &
    
    set_module_prop "无法运行"
    
    log Warn "后续操作被跳过" ${log_dir}/run.log
fi

# -------------------- 设置模块描述 --------------------

DESC=""
[ "${enable_AppOpt}" = "true" ] && is_process_running "AppOpt" && DESC="${DESC}AppOpt运行中，" || DESC="${DESC}AppOpt未运行，"
[ "${enable_adguardhome}" = "true" ] && is_process_running "AdGuardHome" && DESC="${DESC}AdGuardHome运行中，" || DESC="${DESC}AdGuardHome未运行，"
[ "${enable_oxidns}" = "true" ] && is_process_running "oxidns" && DESC="${DESC}oxidns运行中，" || DESC="${DESC}oxidns未运行，"
[ "${enable_smartdns}" = "true" ] && is_process_running "smartdns" && DESC="${DESC}smartdns运行中，" || DESC="${DESC}smartdns未运行，"
[ "${enable_mihomo}" = "true" ] && is_process_running "mihomo" && DESC="${DESC}mihomo运行中，" || DESC="${DESC}mihomo未运行，"

DESC="${DESC}端口:${redir_port}"
set_module_prop ${DESC}
