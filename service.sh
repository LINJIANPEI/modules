#!/system/bin/sh
# -------------------- 引入配置 --------------------

source /data/adb/modules/Linlin/fun.conf


# -------------------- 等待系统就绪 --------------------
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 1
done

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


# 创建软链接
ln -sf "${module_dir}/smartdnsData/smartdns" "${module_dir}/bin/smartdns"
ln -sf "${module_dir}/smartdnsData/lib/libc.so" "${module_dir}/smartdnsData/lib/ld-musl-aarch64.so.1"
ln -sf "${module_dir}/smartdnsData/lib/ld-musl-aarch64.so.1" "${module_dir}/smartdnsData/lib/ld-linux.so"

# 合并验证证书
cat /system/etc/security/cacerts/* > ${module_dir}/smartdnsData/Linlin.crt

# -------------------- 清理log --------------------
clear_log "${log_dir}/run.log" "${log_dir}/AppOpt.log" "${log_dir}/AdGuardHome.log" "${log_dir}/oxidns.log" "${log_dir}/smartdns.log" "${log_dir}/iptables.log" "${log_dir}/mihomoRun.log" "${log_dir}/mihomoRun.log" "${log_dir}/ruleconverter.log" "${log_dir}/oiface.log" "${log_dir}/dns.log"


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


# ==========================================
# 【新增】启动前预处理 IPv6 环境与配置
# ==========================================
# 1. 提前读取配置
: "${block_ipv6:=false}"

# 2. 提前处理系统网栈
if [ "${block_ipv6}" = "true" ]; then
    log Info "前置检测：block_ipv6=true，强制禁用系统 IPv6 网栈" ${log_dir}/run.log
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
    echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
else
    log Info "前置检测：block_ipv6=false，保持系统 IPv6 网栈开启" ${log_dir}/run.log
    echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
    echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1
fi

# 3. 提前修改 AdGuardHome 配置文件
AGH_CONF="${module_dir}/conf/AdGuardHome.yaml"
YAMLCI_BIN="${module_dir}/bin/yamlcli"

if [ -f "$AGH_CONF" ] && [ -x "$YAMLCI_BIN" ]; then
    if [ "${block_ipv6}" = "true" ]; then
        # 如果禁用 IPv6，就只留 127.0.0.1
        CURRENT_BIND=$("$YAMLCI_BIN" -f "$AGH_CONF" get 'dns.bind_hosts' 2>/dev/null)
        if echo "$CURRENT_BIND" | grep -q "::1"; then
            log Info "前置检测：正在移除 AdGuardHome 的 IPv6 监听" ${log_dir}/run.log
            "$YAMLCI_BIN" -f "$AGH_CONF" set 'dns.bind_hosts' '["127.0.0.1"]' >/dev/null 2>&1
        fi
    else
        # 如果启用 IPv6，就恢复双栈（127.0.0.1 和 ::1）
        CURRENT_BIND=$("$YAMLCI_BIN" -f "$AGH_CONF" get 'dns.bind_hosts' 2>/dev/null)
        if ! echo "$CURRENT_BIND" | grep -q "::1"; then
            log Info "前置检测：正在恢复 AdGuardHome 的 IPv6 监听" ${log_dir}/run.log
            "$YAMLCI_BIN" -f "$AGH_CONF" set 'dns.bind_hosts' '["127.0.0.1", "::1"]' >/dev/null 2>&1
        fi
    fi
fi
# ==========================================

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
        -b "Linlin" \
        -w \
        >"${log_dir}/AppOpt.log" 2>&1 &
    ) &
fi

# AdGuardHome
if [ "${enable_adguardhome}" = "true" ]; then
    kill_by_name "AdGuardHome"
    kill_by_name "AghReport"
    (
    ulimit -n "$FD_ADGUARD"
    cd ${module_dir}/adguardHomeData
    nohup busybox setuidgid ${uid}:${gid} \
        "${module_dir}/bin/AdGuardHome" \
        -c "${module_dir}/conf/AdGuardHome.yaml" \
        -w "${module_dir}/adguardHomeData" \
        --no-check-update \
        >"${log_dir}/AdGuardHome.log" 2>&1 &
    ) &
    nohup "${module_dir}/bin/AghReport" &
fi


# oxidns
if [ "${enable_oxidns}" = "true" ]; then
    kill_by_name "oxidns"
    (
    ulimit -n "$FD_OXIDNS"
    cd ${module_dir}/oxidnsData
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
    cd ${module_dir}/smartdnsData
    nohup busybox setuidgid ${uid}:${gid} \
        "${module_dir}/bin/smartdns" \
        -c "${module_dir}/conf/smartdns.conf" \
        -f \
       >"${log_dir}/smartdns.log" 2>&1 &
    ) 
    #"${module_dir}/scripts/updateSmartdnsRules.sh" &
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
        "${module_dir}/scripts/dns.sh" enable &
    else
        "${module_dir}/scripts/dns.sh" disable &
    fi 
    
    "${module_dir}/scripts/clearLog.sh" &
    
    if [ "${enable_oiface}" = "true" ]; then    
      "${module_dir}/scripts/oiface.sh" enable &
    elif [ "${enable_oiface}" = "false" ]; then 
      "${module_dir}/scripts/oiface.sh" disable &
    fi 
    
    if [ "${enable_usb}" = "true" ]; then    
      "${module_dir}/scripts/usb.sh" enable &
    elif [ "${enable_usb}" = "false" ]; then 
      "${module_dir}/scripts/usb.sh" disable &
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
[ "${enable_mihomo}" = "true" ] && is_process_running "mihomo" && DESC="${DESC}mihomo运行中。" || DESC="${DESC}mihomo未运行。"

set_module_prop ${DESC}
