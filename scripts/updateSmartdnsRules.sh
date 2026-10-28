#!/system/bin/sh
# SmartDNS 规则自动更新（合并版）
# 路径：/data/adb/modules/Linlin/scripts/updateSmartdnsRules.sh
# 用法：
#   updateSmartdnsRules.sh          -> 登记 cron 任务并确保 crond 运行
#   updateSmartdnsRules.sh update   -> 执行规则下载与重启 SmartDNS（由 cron 调用）

source /data/adb/modules/Linlin/fun.conf

SCRIPT_PATH="${module_dir}/scripts/updateSmartdnsRules.sh"
cron_dir="${module_dir}/cron"
cron_file="${cron_dir}/root"
update_cmd="30 5 * * * /system/bin/sh ${SCRIPT_PATH} update"

RULE_DIR="/data/adb/modules/Linlin/oxidnsData/rules"
LOG_FILE="${log_dir}/smartdns_rules_update.log"
BASE_URL="https://raw.githubusercontent.com/LINJIANPEI/mosdnsRules/main/rule"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ==========================================
# 角色一：登记任务 + 确保 crond 运行
# ==========================================
if [ "$1" != "update" ]; then
    mkdir -p "$cron_dir"

    # 追加且去重
    if [ ! -f "$cron_file" ]; then
        echo "$update_cmd" > "$cron_file"
    elif ! grep -Fxq "$update_cmd" "$cron_file"; then
        echo "$update_cmd" >> "$cron_file"
    fi

    # 确保 crond 运行（如果尚未运行）
    if ! pgrep -f "crond -c $cron_dir" >/dev/null 2>&1; then
        busybox crond -c "$cron_dir" -b
    fi

    exit 0
fi

# ==========================================
# 角色二：下载规则 + 重启 SmartDNS
# ==========================================
mkdir -p "$(dirname "$LOG_FILE")"
log_msg "=== SmartDNS 规则更新开始 ==="
log_msg "重启时将使用 FD_SMARTDNS=${FD_SMARTDNS:-未定义}"

# ---------- 下载并替换规则文件 ----------
for rule_file in cn_domain.txt cdn_domain.txt nocn_domain.txt; do
    url="${BASE_URL}/${rule_file}"
    tmp_file="/data/local/tmp/${rule_file}.tmp"

    log_msg "下载: ${rule_file}"
    curl -sL --connect-timeout 15 --max-time 60 "$url" -o "$tmp_file"

    if [ -s "$tmp_file" ]; then
        mv "$tmp_file" "${RULE_DIR}/${rule_file}"
        log_msg "已更新: ${rule_file} ($(wc -l < "${RULE_DIR}/${rule_file}") 行)"
    else
        log_msg "失败或为空，保留原文件: ${rule_file}"
        rm -f "$tmp_file"
    fi
done

# ---------- 终止旧 SmartDNS 进程 ----------
OLD_PID=$(pgrep -f "${module_dir}/bin/smartdns" | head -n 1)
if [ -n "$OLD_PID" ]; then
    log_msg "终止旧 SmartDNS 进程 (PID: $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null

    i=0
    while pgrep -f "${module_dir}/bin/smartdns" >/dev/null 2>&1 && [ $i -lt 10 ]; do
        sleep 0.5
        i=$((i + 1))
    done
else
    log_msg "未找到旧 SmartDNS 进程，直接启动"
fi

# ---------- 用 service.sh 的原始方式重新启动 ----------
log_msg "重新启动 SmartDNS"

calc_all_fd

(
ulimit -n "$FD_SMARTDNS"
cd "${module_dir}/smartdnsData"
nohup busybox setuidgid "${uid}:${gid}" \
    "${module_dir}/bin/smartdns" \
    -c "${module_dir}/conf/smartdns.conf" \
    -f \
    >"${log_dir}/smartdns.log" 2>&1 &
)

sleep 1
NEW_PID=$(pgrep -f "${module_dir}/bin/smartdns" | head -n 1)
if [ -n "$NEW_PID" ]; then
    log_msg "SmartDNS 已重启，新 PID: $NEW_PID"
else
    log_msg "警告：SmartDNS 重启后未检测到进程，请检查 ${log_dir}/smartdns.log"
fi

# ---------- 更新日志超过 1MB 则清空 ----------
if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE") -gt 1048576 ]; then
    > "$LOG_FILE"
    log_msg "日志超过 1MB，已清空"
fi

log_msg "=== SmartDNS 规则更新结束 ==="