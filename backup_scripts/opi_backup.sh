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

function state_update {
	debug "$2"
	echo '{"state":"'$1'", "desc":"'$2'","max_states":"'$max_states'"}' > $statefile
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

# Test if any backup operations are running.
# the lock file is set by mount_fs which is sourced by "all" scripts (except this).
# the lock is released with the script exits (either mount_fs directly of the scripte that sourced it.)
exec {lock_fd}>${MOUNTLOCK}
flock -n "$lock_fd" || { warn "LOG_INFO" "Unable to run backup, other backup opertations already running."; exit 0 ;}

# release the lock so that the mount process can get the lock
flock -u "$lock_fd"



if enabled=$(kgp-sysinfo -p -c backup -k enabled) ; then
	if [[ $enabled -ne 1 ]] ; then
		debug "Backup disabled"
		exit 0
	fi
else
	warn "LOG_DEBUG" "Missing 'backup->enabled' parameter in 'sysconfig'"
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
	state_update $((max_states - 1)) "Updating database with new meta data"
	# link existing backups
	if [[ ! -z "$DEBUG" ]]; then
		"./link_backup.sh" ${args} 2>&1 | tee -a $error_log
	else
		"./link_backup.sh" ${args} &>> $error_log
	fi
fi

# acknowledge the "start message"
msgcount=$(kgp-notifier -a $msgid)

if [ $s3ql_retval -ne 0 ]; then
	state_update $max_states "Backup job failed"
	warn "LOG_ERR" "Backup failed, please see admin interface for further details "
	exit $s3ql_retval
else
	state_update $max_states "Backup job completed"
fi


