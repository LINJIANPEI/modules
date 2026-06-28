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
    local source="/data/adb/modules/${module_name}/$1"
    local target="$MODPATH/${2:-$1}"
    
    if [ -e "$source" ]; then
        # 确保目标父目录存在
        mkdir -p "$(dirname "$target")"
        
        # 删除已存在的目标（避免 cp 到目录内的问题）
        [ -e "$target" ] && rm -rf "$target"
        
        # 复制文件/文件夹
        cp -r "$source" "$target"
        ui_print "✓ 已保留: $1"
        return 0
    else
        ui_print "! 未找到: $1，使用默认配置"
        return 1
    fi
}


ui_print "********************************************"
ui_print "- 保留配置"
ui_print "********************************************"

preserve_existing_config "config.conf"
preserve_existing_config "conf/AdGuardHome.yaml"
preserve_existing_config "conf/applist.prop"
preserve_existing_config "conf/mihomo.yaml"
preserve_existing_config "conf/oxidns.yaml"
preserve_existing_config "conf/smartdns.conf"
preserve_existing_config "mihomoData/proxies"
preserve_existing_config "mihomoData/cache.db"
preserve_existing_config "mihomoData/packages.list"
preserve_existing_config "cache/smartdns.cache"
preserve_existing_config "cache/oxidns.cache"
preserve_existing_config "adguardHomeData/data"






set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

set_perm $MODPATH/bin/AppOpt 0 0 0755
set_perm $MODPATH/bin/AdGuardHome 0 0 0755
set_perm $MODPATH/bin/oxidns 0 0 0755
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

set_perm $MODPATH/smartdnsData/smartdns 0 0 0755
set_perm $MODPATH/smartdnsData/smartdns_ui.so 0 0 0755
set_perm $MODPATH/smartdnsData/lib/libc.so 0 0 0755
set_perm $MODPATH/smartdnsData/lib/libcrypto.so.3 0 0 0755
set_perm $MODPATH/smartdnsData/lib/libgcc_s.so.1 0 0 0755
set_perm $MODPATH/smartdnsData/lib/libssl.so.3 0 0 0755


ui_print "********************************************"
ui_print "安装完成！"
ui_print "********************************************"
