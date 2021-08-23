#!/bin/bash
#set -x

DEBUG=0
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf
source backup.lib.sh

function exit_fail {
	# Exit codes for s3ql documented in http://www.rath.org/s3ql-docs/man/
	# Additional:
	#  70 : No valid backend specified
	#  71 : No suitable target
	#  75 : Missing filesystem during restore
	#  90 : Missing 'bucket' for s3 backend
	#  98 : This script is already running, and we can only have one instance running.
	#  99 : Device locked
	if [[ ! -z "$plaintext" ]]; then
		red=""
		green=""
		nc=""
		purple=""
		yellow=""
	fi
	echo ""
	echo -e "${red}Error detected, exit code '$1'${nc}"
	if [ ! -z "$2" ]; then
		echo -e "${purple}Message: $2${nc}"
		logger "${purple}Message: $2${nc}"
	fi
	echo "s3ql exit codes documented here: http://www.rath.org/s3ql-docs/man/"
	echo "Additional Codes defined by this script:"
	echo "   1 : General, unspecified error "
	echo "  70 : No valid backend specified "
	echo "  71 : No suitable target "
	echo "  75 : Missing filesystem during restore "
	echo "  80 : Possible FS too new"
	echo "  90 : Missing 'bucket' for s3 backend "
	echo "  98 : Mount process already in progress "
	echo "  99 : Unit locked"
	exit $1

}

function check_fail {
	# checks the argument agains the "PASS" variable and exit's if it does not pass.
	# Indented to be used as "check_fail $?"
	retval=$1
	if [[ $retval -ne $PASS ]]; then
		exit_fail $retval $2
	fi
}

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# limit is used together with "-m" to limit the number of "versions" to mount
# default only mount the newest verson.
limit=1


function usage() {
	echo "Usage: $0 [options]"
	echo "       -a authfile   authfile to use"
	echo "       -b backend    backend to use" 
	echo "       -m mountpoint mountpoint"
	echo "       -l limit      ??"
	echo "       -p            Dont use colors in output"
	echo "       -f            Force check of locked system"
	echo "                     useful for debug."
	echo "       -?            This help"
	exit 1
}


# cmd-line overrides config file parameters.
while getopts "b:a:m:l:rdpf" opt; do
	case "$opt" in
	a)  auth_file=$OPTARG
		;;
	b)  backend=$OPTARG
		;;
	m)  mountpoint=$OPTARG
		;;
	d)  DEBUG=1
		;;
	l)  limit=$OPTARG
		;;
	p)  
		# do not use any colors in output
		plaintext=1
		;;
	f)
		# use to force mount on a locked system, useful for debug.
		force=1
		;;
	?)
		usage
		;;
	esac
done

exec {lock_fd}>"${MOUNTLOCK}"
flock -n "$lock_fd" || { echo "Mount process already running"; exit_fail $ScriptRunning; }


if device_mountpath=$(kgp-sysinfo -c backup -k devicemountpath -p); then
	debug "Using local mount path '$device_mountpath'"
else
	exit_fail 1 "Missing 'backup->devicemountpath' parameter in 'sysconfig'"
fi

if [ -z "$auth_file" ]
then
	if auth_file=$(kgp-sysinfo -c backup -k authfile -p); then
		debug "Using '$auth_file' for auth."
	else
		exit_fail 1 "Missing 'backup->authfile' parameter in 'sysconfig'"
	fi

fi

bucket=$(kgp-sysinfo -c backup -k bucket -p)


if ! enabled=$(kgp-sysinfo -c backup -k enabled -p) || [ $enabled -eq 0 ]; then
	debug "Backup disabled"
	exit 0
fi

if backend=$(kgp-sysinfo -p -c backup -k backend) ; then
	if [[ $backend == 'none' ]] ; then
		debug "Backup disabled"
		exit 0
	fi
	# check for a locked system
	if [[ $force -ne 1 ]] && locked=$(kgp-sysinfo -l) ; then
    	exit_fail $SystemLocked "Failed to run backup, unit locked."
    fi
else
	exit_fail $NoSuitableTarget "Missing 'backup->backend' parameter in 'sysconfig'"
fi



shift $((OPTIND-1))

[ "$1" = "--" ] && shift


backend_ok=$FAIL
for b in "${backends[@]}"; do
	if [[ $b == $backend ]]; then
		echo "'$backend' is a supported backend"
		backend_ok=$PASS
		break
	fi
done
if [[ $backend_ok -ne $PASS ]]; then
	echo "'$backend' is not a valid backend"
	exit_fail $NoBackendSpecified
fi


# find out if there are any mounted backend
declare -A valid_backends

# get_valid_backends populates the global "valid_backends" array
get_valid_backends $backend

debug "Number of valid backends: ${#valid_backends[@]}"
if [[ ${#valid_backends[@]} -gt 0 ]]; then
	# Nothing more to do, use the valid backend(s)
	# Do not exit here since this script is sourced by the backup-scirpts
	# and and "exit" will terminate that script.

	# Backend is mounted, cant run fsck.

	echo "Fs mounted, unable to perform fsck"
	exit 1
else

	echo "No currently valid backends."

	case $backend in
		"s3op://")
			# require account id (unit-id) and CA to validate server.
			if unit_id=$(kgp-sysinfo -c hostinfo -k unitid -p); then
				debug "Using id: '$unit_id'"
			else
				exit_fail 1 "Missing 'hostinfo->unitid' parameter in 'sysconfig'"
			fi

			# TODO: Remove all references to ca_path
			ca_path=" "
			;;
		"local://")
			# check if we have a usb-mem mounted somewhere
			path=$(get_localpath)
			if [[ -z "$path" ]]; then
				# no mem mounted, try to get one
				path=$(mount_localdevice)
				if [[ -z "$path" ]]; then
					# there is no suitable device mounted
					exit_fail $NoSuitableTarget "No Suitable Target"
				fi
			fi
			;;
		"s3://")
			# setup path to be 'bucket' read from target.conf
			path=$bucket
			;;
		*)
			;;
	esac

	echo "Backend to use: $backend"
	declare -A storage_urls
	declare -A CA
	declare -A valid_fs

	# get the storage backend url(s)
	echo "Setup storage URLs"
	get_urls $path
	check_fail $? "Failed to get storage urls"

	# Create cache dir
	sudo mkdir -p $s3ql_cachedir
	check_fail $? "Failed to create cache dir"

	echo "Remove any existing old symlinks"
	removelinks $nextcloud_dir
	check_fail $? "Failed remove symlinks to NextCloud dirs"

	for version in "${versions[@]}"
	do
		echo -n "Running FSCK for version '$version' ..."
		fsck $version
		retval=$?
		echo "  DONE, result '$retval'"
		debug "Version: $version, Valid: $retval"
		valid_fs[$version]=$retval
	done

	for version in "${versions[@]}"
	do
		case ${valid_fs[$version]} in
			0)
				debug "Valid FS for version '$version'"
				;;
			14)
				debug "'$version': Invalid credentials."
				;;
			16|18)
				if [[ ${valid_fs[$version]} -eq 16 ]]; then
					debug "'$version': Invalid storage URL, specified location does not exist in backend."
				else
					debug "No FS for version '$version' found."
				fi
				;;

			17)
				debug "'$version': Invalid passphrase"
				;;

			$PossibleFSTooNew)
				debug "'$version': Unexpected error, possible 2.21 FS with 2.7 backend."
				;;
			128)
				debug "'$version': Filesystem repaired"
				;;
			*)
				debug "'$version': Unexpected error from FSCK"
				;;
		esac
	done


	if [[ ${#valid_fs[@]} -gt 0 ]]
	then
		debug "Got valid FS"
	else
		debug $NoSuitableTarget "No valid targets for backup"
		exit 1
	fi

	debug "FSCK completed succesfully"
fi






