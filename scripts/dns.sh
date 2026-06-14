#!/system/bin/sh

# 关闭私人 DNS
[ "$(settings get global private_dns_mode)" != "off" ] && settings put global private_dns_mode off
# 清空 IFW
[ -d "/data/system/ifw" ] && rm -rf /data/system/ifw/*
