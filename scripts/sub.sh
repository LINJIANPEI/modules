#!/system/bin/sh

MODULE_DIR="/data/adb/modules/Linlin"
MIHOMO_CFG="$MODULE_DIR/conf/mihomo.yaml"
YAMLCI="$MODULE_DIR/bin/yamlcli"

ACTION="$1"
[ ! -f "$MIHOMO_CFG" ] && { echo "配置文件不存在: $MIHOMO_CFG" >&2; exit 1; }

list_subs() {
    # 先获取所有的订阅名称（去掉 map[] 外壳，并用 awk 精准提取顶格的键名）
    RAW=$("$YAMLCI" -f "$MIHOMO_CFG" get proxy-providers 2>/dev/null)
    [ -z "$RAW" ] && return

    # 提取出名字列表
    echo "$RAW" | tr ' ' '\n' | grep -oE '^[^:]+:map\[' | sed 's/:map\[//' | while read -r name; do
        # 过滤空字符
        [ -z "$name" ] && continue
        
        # 直接使用 yamlcli 精准定位该名字下的 url，绝不抓错！
        url=$("$YAMLCI" -f "$MIHOMO_CFG" get "proxy-providers.$name.url" 2>/dev/null | tr -d '"' | tr -d "'")
        
        # 如果抓出来的 url 是空的，或者包含了 generate_204，就跳过不显示
        if [ -n "$url" ] && [[ "$url" != *"generate_204"* ]]; then
            echo "$name|$url"
        fi
    done
}

add_sub() {
    NAME="$1"; URL="$2"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.type" "http"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.url" "$URL"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.interval" "3600"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.path" "./proxy_providers/$NAME.yaml"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.health-check.enable" "true"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.health-check.url" "https://www.gstatic.com/generate_204"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.health-check.timeout" "1500"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.health-check.interval" "300"
    "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NAME.health-check.lazy" "true"
}

edit_sub() {
    OLD_NAME="$1"; NEW_NAME="$2"; URL="$3"
    if [ "$OLD_NAME" != "$NEW_NAME" ]; then
        "$YAMLCI" -f "$MIHOMO_CFG" del "proxy-providers.$OLD_NAME"
        add_sub "$NEW_NAME" "$URL"
    else
        "$YAMLCI" -f "$MIHOMO_CFG" set "proxy-providers.$NEW_NAME.url" "$URL"
    fi
}

del_sub() {
    IDX="$1"
    OLD=$(list_subs | sed -n "$((IDX+1))p" | cut -d'|' -f1)
    [ -z "$OLD" ] && { echo "索引越界" >&2; exit 1; }
    "$YAMLCI" -f "$MIHOMO_CFG" del "proxy-providers.$OLD"
}

case "$ACTION" in
    list) list_subs ;;
    add)  add_sub "$2" "$3" ;;
    edit) edit_sub "$2" "$3" "$4" ;;
    del)  del_sub "$2" ;;
    *) echo "未知操作: $ACTION" >&2; exit 1 ;;
esac

if [ "$ACTION" != "list" ]; then
    "$MODULE_DIR/scripts/control.sh" mihomo stop >/dev/null 2>&1
    sleep 1
    "$MODULE_DIR/scripts/control.sh" mihomo start >/dev/null 2>&1
fi
exit 0