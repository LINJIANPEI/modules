#!/system/bin/sh

ui_print "- 正在检测Hosts模块"
found_hosts=false
for module in /data/adb/modules/*; do
    [ -f "${module}/system/etc/hosts" ] && [ -f "${module}/module.prop" ] && {
        [ "$found_hosts" = false ] && ui_print "- 发现Hosts模块，正在自动移除:" && found_hosts=true
        ui_print "  $(grep_prop name "${module}/module.prop")"
        touch "${module}/remove"
    }
done
[ "$found_hosts" = true ] && ui_print "- 冲突模块已标记移除，安装完成后请重启设备。"

set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

set_perm $MODPATH/bin/AppOpt 0 0 0755
set_perm $MODPATH/bin/AdGuardHome 0 0 0755
set_perm $MODPATH/bin/oxidns 0 0 0755
set_perm $MODPATH/bin/smartdns 0 0 0755
set_perm $MODPATH/bin/curl 0 0 0755
set_perm $MODPATH/bin/mihomo 0 0 0755
set_perm $MODPATH/bin/yamlcli 0 0 0755
set_perm $MODPATH/bin/ruleconverter 0 0 0755

set_perm $MODPATH/scripts/iptables.sh 0 0 0755
set_perm $MODPATH/scripts/dns.sh 0 0 0755
set_perm $MODPATH/scripts/clearLog.sh 0 0 0755
set_perm $MODPATH/scripts/clash.sh 0 0 0755
set_perm $MODPATH/scripts/action.sh 0 0 0755
set_perm $MODPATH/scripts/oiface.sh 0 0 0755