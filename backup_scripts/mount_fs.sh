#!/bin/bash
#set -x

DEBUG=0
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR
source /etc/opi/sysinfo.conf
source backup.conf
source backup.lib.sh

function exit_fail {
	# Exit codes for s3ql documented in http://www.rath.org/s3ql-docs/man/
	# Additional:
	#  70 : No valid backend specified
	#  71 : No suitable target
	#  75 : Missing filesystem during restore
	#  90 : Missing 'bucket' for s3 backend
	#  99 : Device locked (luksdevice not present in /proc/mounts)
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
	fi
	echo "s3ql exit codes documented here: http://www.rath.org/s3ql-docs/man/"
	echo "Additional Codes defined by this script:"
	echo "   1 : General, unspecified error "
	echo "  70 : No valid backend specified "
	echo "  71 : No suitable target "
	echo "  75 : Missing filesystem during restore "
	echo "  80 : Possible FS too new"
	echo "  90 : Missing 'bucket' for s3 backend "
	echo "  99 : Unit locked"
	exit $1

}

function check_fail {
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


# cmd-line overrides config file parameters.
while getopts "b:a:m:l:rdp" opt; do
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
	?)	exit 1
		;;
	esac
done

systype=$(kgp-sysinfo -tp | grep "typeText" | awk '{print $2}')
debug "Running on '${systype}'"

if [[ "$systype" == "Opi" ]]; then
    # OPI does not have enough memory
    s3ql_cachesize=$s3ql_cachesize_OPI
fi


if [ $restore -ne 1 ]
then
	if [ -e $target_file ]; then
		source  $target_file
	else   
		echo "No target file"
		exit_fail $NoSuitableTarget
	fi
else
	# We are doing restore, no cryptvolume available yet
	# override some defaults
	s3ql_cachedir=/tmp/s3qltmp
fi


shift $((OPTIND-1))

[ "$1" = "--" ] && shift

if [[ "$backend" == "none" ]]; then
	debug "Nothing to do for backend '$backend'"
	exit 0
fi

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

				if [[ $version == $CURRENT_VERSION && $restore -ne 1 ]]; then
					debug "Create FS with verson '$version'"
					create_fs 
					valid_fs[$version]=$?
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
		exit_fail $NoSuitableTarget "No valid targets for backup"
	fi

	if [[ ${#valid_backends[@]} -eq 0 ]]; then
		exit_fail $NoSuitableTarget "No Suitable Target"
	fi


fi
# this script is 'sourced' from s3ql-backup and must not exit if nothing is wrong.






