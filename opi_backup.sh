#!/bin/bash
cd $(dirname "${BASH_SOURCE[0]}")
source backup.conf

echo "none" > "/sys/class/leds/opi:red:usr3/trigger"

if [ -e $target_file ]; then
	source $target_file # reads which backend to use
	sd_card=$(sed -n "s%\(/dev/mmcblk\w*\)\s/var/opi.*%\1% p" /proc/mounts) # get sd-card device
	if [ -z $backend ] || [[ $backend == *none* ]] || [ -z $sd_card ] || [ ! -b $sd_card ]; then
		# the backend must be defined and the sd-card device must exist and be mounted
		echo "Backup not enabled"
		exit 0
	fi
else
	echo "Backup not enabled"
	exit 0
fi

error_log="${logdir}/backup.log"
alert_file="${logdir}/alert"

rm -f $error_log
rm -f $alert_file

if [ ! -d $logdir ]; then
	# create dir
	mkdir $logdir
fi

echo "heartbeat" > "/sys/class/leds/opi:green:usr1/trigger"

cd ${backupbin_path} 
"./s3ql_backup.sh" &> $error_log


if [ $? -ne 0 ]; then
	echo "Backup failed, check log file: $error_log"
	echo "Backup failed, check log file: $error_log" > $alert_file
	echo "heartbeat" > "/sys/class/leds/opi:red:usr3/trigger"
else
	"./link_backup.sh" &>> $error_log
fi

echo "default-on" > "/sys/class/leds/opi:green:usr1/trigger"

