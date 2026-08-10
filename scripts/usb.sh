#!/system/bin/sh

case "$1" in
    enable)
        sleep 30
        settings put global adb_enabled 0
        setprop persist.sys.usb.config mtp
        stop adbd
        echo "ADB disabled."
        ;;
    disable)
        settings put global adb_enabled 1
        setprop persist.sys.usb.config mtp,adb
        start adbd
        echo "ADB enabled."
        ;;
    *)
        echo "Usage: $0 {enable|disable}"
        exit 1
        ;;
esac

exit 0