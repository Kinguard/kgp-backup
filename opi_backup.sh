#!/bin/bash
cd $(dirname "${BASH_SOURCE[0]}")
source backup.conf

#sd card location
def_sdcard="/dev/mapper/opi"
def_opiloc="/var/opi"

error_log="${logdir}/backup.log"
alert_file="${logdir}/alert"

echo "none" > "/sys/class/leds/opi:red:usr3/trigger"

function report_error {
	echo "$1 (Possibly more informaton in log file: $error_log)" > $alert_file
	echo "$1 (Possibly more informaton in log file: $error_log)"
	echo "heartbeat" > "/sys/class/leds/opi:red:usr3/trigger"
	echo "default-on" > "/sys/class/leds/opi:green:usr1/trigger"
	exit 1
}

if [ -e $target_file ]; then
	source $target_file # reads which backend to use
	#validate backend
	if [ $backend == 'local://' ] || [ $backend == 's3op://' ]; then 	
	# valid backend
		sd_card=$(sed -n "s%\(${def_sdcard}\)\s${def_opiloc}.*%\1% p" /proc/mounts) # get sd-card device
		if [ -z $sd_card ] || [ ! -b $sd_card ]; then
			# the backend must be defined and the sd-card device must exist and be mounted
			report_error "Backup aborted, no sd card found or sd card is not unlocked"
		else
			echo "Starting backup"
		fi
	else
		if [ $backend == 'none' ] ; then
			echo "Backup not enabled"
			exit 0
		else 
			report_error "Unknown backend: $backend"
		fi
	fi	
else
	report_error "Backup aborted, no target file found"
fi



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
	report_error "Backup failed"
else
	"./link_backup.sh" &>> $error_log
fi

echo "default-on" > "/sys/class/leds/opi:green:usr1/trigger"

