#!/system/bin/sh
source /data/adb/modules/Linlin/fun.conf


	# 屏蔽 msm_irqbalance
	for SYSPERFCONFIG in $(ls /system/vendor/bin/msm_irqbalance); do
		mkdir -p $module_dir${SYSPERFCONFIG%/*}
		touch $module_dir$SYSPERFCONFIG
	done
	
    for MAX_CPUS in /sys/devices/system/cpu/cpu*/core_ctl/max_cpus; do
	   if [ -e "$MAX_CPUS" ] && [ "$(cat $MAX_CPUS)" != "$(cat ${MAX_CPUS%/*}/min_cpus)" ]; then
	       chmod a+w "${MAX_CPUS%/*}/min_cpus"
		   echo "$(cat $MAX_CPUS)" > "${MAX_CPUS%/*}/min_cpus"
	       chmod a-w "${MAX_CPUS%/*}/min_cpus"
	   fi
    done

    [ -n "$(getprop persist.sys.oiface.enable)" ] && setprop persist.sys.oiface.enable 0
