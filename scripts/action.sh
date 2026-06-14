#!/system/bin/sh
source /data/adb/modules/Linlin/fun.conf

if is_process_running "mihomo"; then
    echo "正在停止akashaProxy."
    ${module_dir}/scripts/clash.sh display && ${module_dir}/scripts/iptables.sh switch_to_adguard
else
    echo "正在启动akashaProxy."
    ${module_dir}/scripts/clash.sh enable && ${module_dir}/scripts/iptables.sh switch_to_mihomo
fi

DESC=""
[ "${enable_AppOpt}" = "true" ] && is_process_running "AppOpt" && DESC="${DESC}AppOpt运行中，" || DESC="${DESC}AppOpt未运行，"
[ "${enable_mihomo}" = "true" ] && is_process_running "mihomo" && DESC="${DESC}mihomo运行中，" || DESC="${DESC}mihomo未运行，"
[ "${enable_adguardhome}" = "true" ] && is_process_running "AdGuardHome" && DESC="${DESC}AdGuardHome运行中，" || DESC="${DESC}AdGuardHome未运行，"
[ "${enable_oxidns}" = "true" ] && is_process_running "oxidns" && DESC="${DESC}oxidns运行中，" || DESC="${DESC}oxidns未运行，"
[ "${enable_smartdns}" = "true" ] && is_process_running "smartdns" && DESC="${DESC}smartdns运行中，" || DESC="${DESC}smartdns未运行，"

DESC="${DESC}端口:${redir_port}"
set_module_prop ${DESC}