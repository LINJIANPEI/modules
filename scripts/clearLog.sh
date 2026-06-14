#!/system/bin/sh
source /data/adb/modules/Linlin/fun.conf

cron_dir="${module_dir}/cron"
cron_file="${cron_dir}/root"
clear_cmd="*/5 * * * * /system/bin/sh ${module_dir}/scripts/clearLog.sh"

mkdir -p "$cron_dir"

# 追加且去重（和修改后的规则更新逻辑一致）
if [ ! -f "$cron_file" ]; then
    echo "$clear_cmd" > "$cron_file"
elif ! grep -Fxq "$clear_cmd" "$cron_file"; then
    echo "$clear_cmd" >> "$cron_file"
fi

# 确保 crond 运行（如果尚未运行）
if ! pgrep -f "crond -c $cron_dir" >/dev/null 2>&1; then
    busybox crond -c "$cron_dir" -b
fi

# 清空超过 100MB 的文件
auto_clear_logs $((2 * 1024 * 1024)) "${log_dir}/run.log" "${log_dir}/AppOpt.log" "${log_dir}/AdGuardHome.log" "${log_dir}/oxidns.log" "${log_dir}/smartdns.log" "${log_dir}/iptables.log" "${log_dir}/mihomoRun.log" "${log_dir}/ruleconverter.log"

