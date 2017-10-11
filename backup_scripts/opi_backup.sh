#!/bin/bash
DIR=$(dirname "${BASH_SOURCE[0]}")
cd $DIR

source backup.conf

ISSUER="Backup System"

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
	if [ $backend == 'none' ] ; then
		report "Backup not enabled"
		exit 0
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
./s3ql_backup.sh &> $error_log
s3ql_retval=$?
# acknowledge the "start message"
kgp-notifier -a $msgid

# link existing backups
"./link_backup.sh" &>> $error_log

if [ $s3ql_retval -ne 0 ]; then
	report_error "Backup failed"
fi


