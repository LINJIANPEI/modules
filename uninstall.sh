#!/system/bin/sh

source /data/adb/modules/Linlin/fun.conf
  
    
    
${module_dir}/scripts/clash.sh disable &
${module_dir}/scripts/iptables.sh disable &
"${module_dir}/scripts/oiface.sh" disable &
kill_by_name "smartdns"
kill_by_names "crond -c ${module_dir}/cron"
kill_by_name "oxidns"
kill_by_name "AppOpt"
kill_by_name "AdGuardHome"
   