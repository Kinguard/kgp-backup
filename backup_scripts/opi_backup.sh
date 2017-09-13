#!/bin/bash
source /usr/share/opi-backup/backup.conf

ISSUER="Backup System"

#sd card location
def_sdcard="/dev/mapper/opi"
def_opiloc="/var/opi"

error_log="${logdir}/backup.log"
alert_file="${logdir}/alert"

verbose=$1
function report {
	if [ ! -z $verbose ] && [ $verbose == '-v' ] ; then
		echo $1
	fi
}

function report_error {
	echo "$1" > $alert_file
	echo "$1"

	echo "-------   Content of Logfile $error_log  ------------------"
	cat $error_log
	
	kgp-notifier -m "Backup Failed, see backup admin UI for more information." -l "LOG_ERR" -b -i "${ISSUER}"
	exit 1
}


if [[ ! -z $(pgrep 's3ql_backup.sh') ]] ; then
	echo "Backup already running, exiting"
	exit 0
fi


if [ -e $target_file ]; then
	source $target_file # reads which backend to use
	#validate backend
	echo "Backend $backend"
	if [ $backend == 'local://' ] || [ $backend == 's3op://' ] || [[ $backend == "s3://" ]]; then 	
	# valid backend
		sd_card=$(sed -n "s%\(${def_sdcard}\)\s${def_opiloc}.*%\1% p" /proc/mounts) # get sd-card device
		if [ -z $sd_card ] || [ ! -b $sd_card ]; then
			# the backend must be defined and the sd-card device must exist and be mounted
			echo "Backup aborted, no sd card found or sd card is not unlocked"
			exit 1
		else
			report "Starting backup"
		fi
	else
		if [ $backend == 'none' ] ; then
			report "Backup not enabled"
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

msgid=$(kgp-notifier -l LOG_NOTICE -m "Backup started" -i "${ISSUER}")
echo "MSGID: $msgid"
cd ${backupbin_path} 
./s3ql_backup.sh &> $error_log
s3ql_retval=$?
# acknowledge the "start message"
kgp-notifier -a $msgid

if [ $s3ql_retval -ne 0 ]; then
	report_error "Backup failed"
else
	"./link_backup.sh" &>> $error_log
fi


