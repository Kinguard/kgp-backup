#!/bin/bash
source /etc/opi/backup.conf

if [ $backup_enabled != "yes" ]; then
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

cd ${backupbin_path} 
"./s3ql_backup.sh" &> $error_log

if [ $? -ne 0 ]; then
	echo "Backup failed, check log file: $error_log"
	echo "Backup failed, check log file: $error_log" > $alert_file
fi

"./opi_mount.sh" &> $error_log

