#!/system/bin/sh

# ================================
# 加载基础配置
# ================================
source /data/adb/modules/Linlin/fun.conf

logFile="${log_dir}/dns.log"
uid="${uid}"
gid="${gid}"
ignore_src_list="${ignore_src_list}"
ignore_dest_list="${ignore_dest_list}"
block_ipv6_dns="${block_ipv6_dns}"
DNS_PORT=""

# ================================
# DNS端口选择
# ================================
if [ -n "$2" ]; then
  DNS_PORT="$2"
  log Info "使用传入DNS端口:${DNS_PORT}" "${logFile}"
elif [ "${enable_mihomo}" = true ] && [ "${MIHOMO_DNS_ENABLE}" = true ]; then
  log Info "使用MIHOMO DNS" "${logFile}"
  DNS_PORT=${MIHOMO_DNS_PORT}
else
  log Info "使用ADGUARD DNS" "${logFile}"
  DNS_PORT=${redir_port}
fi

log Info "当前DNS端口:${DNS_PORT}" "${logFile}"

# ================================
# IPv6 NAT能力检测
# ================================
check_ipv6_nat_support() {
  if [ "${block_ipv6_dns}" = true ]; then
    log Info "阻断IPv6" "${logFile}"
    return 1
  fi
  ip6tables -w 64 -t nat -L >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    log Warn "IPv6 NAT不可用" "${logFile}"
    return 1
  fi

  ip6tables -w 64 -t nat -A PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    ip6tables -w 64 -t nat -D PREROUTING -p tcp --dport 65534 -j REDIRECT --to-port 65534 >/dev/null 2>&1
    log Info "IPv6 NAT支持REDIRECT" "${logFile}"
    return 0
  fi

  log Warn "IPv6 NAT不支持REDIRECT" "${logFile}"
  return 1
}

# ================================
# IPv4 REDIRECT规则
# ================================
enable_ipv4_iptables() {
  log Info "启用IPv4 DNS REDIRECT" "${logFile}"

  iptables -w 64 -t nat -N REDIRECT_DNS 2>/dev/null
  iptables -w 64 -t nat -C OUTPUT -j REDIRECT_DNS >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    iptables -w 64 -t nat -I OUTPUT -j REDIRECT_DNS
  fi

  iptables -w 64 -t nat -F REDIRECT_DNS

  iptables -w 64 -t nat -A REDIRECT_DNS -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

  for s in ${ignore_dest_list}; do
    case "$s" in *:*) continue ;; esac
    iptables -w 64 -t nat -A REDIRECT_DNS -d "$s" -j RETURN
  done

  for s in ${ignore_src_list}; do
    case "$s" in *:*) continue ;; esac
    iptables -w 64 -t nat -A REDIRECT_DNS -s "$s" -j RETURN
  done

  iptables -w 64 -t nat -A REDIRECT_DNS -p udp --dport 53 -j REDIRECT --to-ports "${DNS_PORT}"
  iptables -w 64 -t nat -A REDIRECT_DNS -p tcp --dport 53 -j REDIRECT --to-ports "${DNS_PORT}"

  log Info "IPv4 DNS REDIRECT完成" "${logFile}"
}

# ================================
# IPv6 REDIRECT（与IPv4对齐）
# ================================
enable_ipv6_redirect() {
  log Info "启用IPv6 DNS REDIRECT（对齐IPv4）" "${logFile}"

  ip6tables -w 64 -t nat -N REDIRECT_DNS6 2>/dev/null

  ip6tables -w 64 -t nat -C OUTPUT -j REDIRECT_DNS6 >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    ip6tables -w 64 -t nat -I OUTPUT -j REDIRECT_DNS6
  fi

  ip6tables -w 64 -t nat -F REDIRECT_DNS6

  ip6tables -w 64 -t nat -A REDIRECT_DNS6 -m owner --uid-owner "${uid}" --gid-owner "${gid}" -j RETURN

  for s in ${ignore_dest_list}; do
    case "$s" in *:*) ip6tables -w 64 -t nat -A REDIRECT_DNS6 -d "$s" -j RETURN ;; esac
  done

  for s in ${ignore_src_list}; do
    case "$s" in *:*) ip6tables -w 64 -t nat -A REDIRECT_DNS6 -s "$s" -j RETURN ;; esac
  done

  ip6tables -w 64 -t nat -A REDIRECT_DNS6 -p udp --dport 53 -j REDIRECT --to-ports "${DNS_PORT}"
  ip6tables -w 64 -t nat -A REDIRECT_DNS6 -p tcp --dport 53 -j REDIRECT --to-ports "${DNS_PORT}"

  log Info "IPv6 REDIRECT完成" "${logFile}"
}

# ================================
# IPv6 BLOCK（降级模式）
# ================================
enable_ipv6_block() {
  log Warn "IPv6 NAT不可用，启用BLOCK模式" "${logFile}"

  ip6tables -w 64 -t filter -N BLOCK_DNS6 2>/dev/null

  ip6tables -w 64 -t filter -C OUTPUT -j BLOCK_DNS6 >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    ip6tables -w 64 -t filter -I OUTPUT -j BLOCK_DNS6
  fi

  ip6tables -w 64 -t filter -A BLOCK_DNS6 -p udp --dport 53 -j DROP
  ip6tables -w 64 -t filter -A BLOCK_DNS6 -p tcp --dport 53 -j DROP

  log Warn "IPv6 DNS BLOCK完成" "${logFile}"
}

# ================================
# IPv6统一入口（自动选择）
# ================================
enable_ipv6_iptables() {
  check_ipv6_nat_support
  if [ $? -eq 0 ]; then
    enable_ipv6_redirect
  else
    enable_ipv6_block
  fi
}

# ================================
# 启用
# ================================
enable() {
  [ "$(settings get global private_dns_mode)" != "off" ] && settings put global private_dns_mode off
  settings put global private_dns_specifier ""
  [ -d "/data/system/ifw" ] && rm -rf /data/system/ifw/*

  log Info "开始部署DNS劫持规则" "${logFile}"

  enable_ipv4_iptables || { log Error "IPv4失败" "${logFile}"; exit 1; }
  enable_ipv6_iptables || { log Error "IPv6失败" "${logFile}"; exit 1; }

  log Info "DNS劫持部署完成" "${logFile}"
}

# ================================
# 关闭
# ================================
disable() {
  log Info "清理DNS规则" "${logFile}"

  iptables -w 64 -t nat -D OUTPUT -j REDIRECT_DNS >/dev/null 2>&1
  iptables -w 64 -t nat -F REDIRECT_DNS >/dev/null 2>&1
  iptables -w 64 -t nat -X REDIRECT_DNS >/dev/null 2>&1

  ip6tables -w 64 -t nat -D OUTPUT -j REDIRECT_DNS6 >/dev/null 2>&1
  ip6tables -w 64 -t nat -F REDIRECT_DNS6 >/dev/null 2>&1
  ip6tables -w 64 -t nat -X REDIRECT_DNS6 >/dev/null 2>&1

  ip6tables -w 64 -t filter -D OUTPUT -j BLOCK_DNS6 >/dev/null 2>&1
  ip6tables -w 64 -t filter -F BLOCK_DNS6 >/dev/null 2>&1
  ip6tables -w 64 -t filter -X BLOCK_DNS6 >/dev/null 2>&1

  log Info "DNS规则清理完成" "${logFile}"
}

# ================================
# 入口
# ================================
case "$1" in
  enable) enable ;;
  disable) disable ;;
  *) echo "用法: $0 enable|disable [端口]" ;;
esac