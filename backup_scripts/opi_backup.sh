#!/bin/bash
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

ISSUER="Backup System"


function init_logs {
	if [ ! -d $logdir ]; then
		# create dir
		mkdir $logdir
	fi

	# Make sure no "old data is still present"
	rm -f $alert_file
	date > $error_log
}

function warn {
	local msg=$2
	local level=$1
	local msgid

	if [[ "$level" == "LOG_ERR" ]]; then
		# signal error to backend.
		echo "$msg" > $alert_file
	fi
	msgid=$(kgp-notifier -m "$msg" -l "$level" -b -i "${ISSUER}")


	if [[ ! -z "$DEBUG" ]]; then	
		echo "$msg: $level"
		echo "-------   Content of Logfile $error_log  ------------------"
		cat $error_log
	fi	

}
function debug {
	if [[ ! -z "$DEBUG" ]]; then
		echo "$1"
	fi
}

OPTIND=1         # Reset in case getopts has been used previously in the shell.
# cmd-line overrides config file parameters.
args=""
while getopts "dp" opt; do
    case "$opt" in
    d)
		DEBUG=1
		args="$args -d"
	    ;;
    p)  
        # do not use any colors in output
        plaintext=1
		args="$args -p"
        ;;
    *)
		echo "Unknown argument '$opt'"
		exit 1
	    ;;
    esac
done

#set up logfiles
init_logs

if [[ ! -z $(pgrep 's3ql_backup.sh') ]] ; then
	warn "LOG_INFO" "Backup already running, exiting"
	exit 0
fi

if [ -e $target_file ]; then
	source $target_file # reads which backend to use
	if [ $backend == 'none' ] ; then
		debug "Backup not enabled"
		exit 0
	fi	
else
	grep -q $luksdevice /proc/mounts
	if [[ $? -ne 0 ]]; then
    	warn "LOG_WARNING" "Failed to run backup, unit locked."
    	exit 99
	else
		warn "LOG_ERR" "Backup aborted, no target file found"
	fi
	exit 1
fi



msgid=$(kgp-notifier -l LOG_NOTICE -m "Backup started" -i "${ISSUER}")
debug "MSGID: $msgid"

if [[ ! -z "$DEBUG" ]]; then
	./s3ql_backup.sh ${args} 2>&1 | tee -a $error_log
	s3ql_retval=${PIPESTATUS[0]}

else
	./s3ql_backup.sh ${args} &>> $error_log
	s3ql_retval=$?
fi

if [[ $s3ql_retval -eq 0 ]]; then
	# link existing backups
	if [[ ! -z "$verbose" ]]; then
		"./link_backup.sh" ${args} 2>&1 | tee -a $error_log
	else
		"./link_backup.sh" ${args} &>> $error_log
	fi
fi

# acknowledge the "start message"
msgcount=$(kgp-notifier -a $msgid)

if [ $s3ql_retval -ne 0 ]; then
	warn "LOG_ERR" "Backup failed"
	exit $s3ql_retval
fi


