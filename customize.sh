#!/system/bin/sh
ui_print "********************************************"
ui_print "- 正在检测Hosts模块"
ui_print "********************************************"

found_hosts=false
for module in /data/adb/modules/*; do
    [ -f "${module}/system/etc/hosts" ] && [ -f "${module}/module.prop" ] && {
        [ "$found_hosts" = false ] && ui_print "- 发现Hosts模块，正在自动移除:" && found_hosts=true
        ui_print "  $(grep_prop name "${module}/module.prop")"
        touch "${module}/remove"
    }
done
[ "$found_hosts" = true ] && ui_print "- 冲突模块已标记移除，安装完成后请重启设备。"




preserve_existing_config() {
    local module_name=$(basename "$MODPATH")
    local old_file="$1"
    local new_file="${2:-$1}"  # 第二个参数默认等于第一个
    
    local old_config_path="/data/adb/modules/${module_name}/${old_file}"
    local new_config_path="$MODPATH/${new_file}"
    
    if [ -f "$old_config_path" ]; then
        # 如果新配置文件存在，则备份
        if [ -f "$new_config_path" ]; then
            mv "$new_config_path" "${new_config_path}.bak"
        fi
        cp "$old_config_path" "$new_config_path"
        ui_print "✓ 已保留现有配置文件: ${old_file}"
        return 0
    else
        ui_print "! 未找到现有配置: ${old_file}，使用默认配置"
        return 1
    fi
}

preserve_existing_config "config.conf"
preserve_existing_config "conf/AdGuardHome.yaml"
preserve_existing_config "conf/applist.prop"
preserve_existing_config "conf/mihomo.yaml"
preserve_existing_config "conf/oxidns.yaml"
preserve_existing_config "conf/smartdns.conf"



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

ui_print "********************************************"
ui_print "安装完成！"
ui_print "********************************************"

