#!/bin/bash
#set -x

#
# mount_fs.sh
#
# Mount s3ql fs according to config
#
#

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

# Initialize our own variables:
restore=0
# limit is used together with "-m" to limit the number of "versions" to mount
# default only mount the newest verson.
limit=1


function usage() {
	echo "Usage: $0 [options]"
	echo "       -a authfile   authfile to use"
	echo "       -b backend    backend to use" 
	echo "       -m mountpoint mountpoint"
	echo "       -r            mount as for restore"
	echo "       -l limit      ??"
	echo "       -p            Dont use colors in output"
	echo "       -f            Force mount of locked system"
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
	r)  restore=1
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
region=$(kgp-sysinfo -c backup -k region -p)


if [ $restore -ne 1 ]
then
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

else
	# We are doing restore, no cryptvolume available yet
	# override some defaults
	s3ql_cachedir=/tmp/s3qltmp
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
	echo "Using existing backends"
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
			path=${region}/${bucket}
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

				if [[ $version == $CURRENT_VERSION && $restore -ne 1 ]]; then
					debug "Create FS with verson '$version'"
					create_fs 
					valid_fs[$version]=$?
				fi
				;;
			17)
				debug "'$version': Invalid passphrase"
				;;

			32)
				debug "OS version newer than filesystem, upgrade required"
				if upgrade_fs
				then
					debug "Upgrade succesful, proceed try mounting"
					valid_fs[$version]=0
				else
					debug "Upgrade failed!!"
				fi
				;;
			$PossibleFSTooNew)
				debug "'$version': Unexpected error, possible 2.21 FS with 2.7 backend."
				;;
			128)
				debug "'$version': Filesystem repaired"
				;;
			*)
				debug "'$version': Unexpected error from FSCK"
				if [[ ! -z "$path" ]] && mountpoint -q "$path"
				then
					debug "Umounting $path since we failed"
					sudo umount "$path"
				else
					debug "$path not mounted so we dont umount"
				fi
				;;
		esac
	done


	if [[ ${#valid_fs[@]} -gt 0 ]]; then
		# Mount valid FS's
		for version in "${versions[@]}"
		do
			if [[ ${valid_fs[$version]} -eq 0 || ${valid_fs[$version]} -eq 128 ]]; then
				echo "Trying to mount FS with '$version'"
				if [[ ! -z "$mountpoint" ]]; then
					# override mountpoint, mount the first valid FS found
					# prio order is set by "versions" array
					echo "Using mountpoint override '$mountpoint'"
					if [[ $limit -eq 1 ]]; then
						m=$mountpoint
					else
						m="${mountpoint}${local_fsprefix[$version]}"
					fi
				else
					m=${mountpoints[$version]}
				fi
				mount_fs $version $m
				status=$?
				# exit if we failed to mount, this would be odd since we have passed FSCK
				# so abort...
				check_fail $status "Failed to mount FS"

				debug "Mounted $backend"
				valid_backends["$version on $backend"]=$m
				if [[ ! -z "$mountpoint" && ${#valid_backends[@]} -eq $limit ]]; then
					debug "Limit to $limit mounted FS('s)"
					break
				fi
			fi
		done
	else
		if mountpoint -q $device_mountpath
		then
			debug "Umounting $device_mountpath"
			umount $device_mountpath
		fi

		exit_fail $NoSuitableTarget "No valid targets for backup"
	fi

	if [[ ${#valid_backends[@]} -eq 0 ]]; then

		if mountpoint -q $device_mountpath
		then
			debug "Umounting $device_mountpath"
			umount $device_mountpath
		fi

		exit_fail $NoSuitableTarget "No Suitable Target"
	fi


fi
# this script is 'sourced' from s3ql-backup and must not exit if nothing is wrong.






