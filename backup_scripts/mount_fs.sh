#!/bin/bash

cd $(dirname "${BASH_SOURCE[0]}")
source /usr/share/opi-backup/backup.conf
source /etc/opi/sysinfo.conf

if [ -e $target_file ]; then
	source  $target_file
else
	echo "Missing target file or OPI is still locked"
	exit 1
fi
#set -x

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
restore=0

while getopts "b:a:m:r" opt; do
    case "$opt" in
    a)  auth_file=$OPTARG
        ;;
    b)  backend=$OPTARG
        ;;
    m)  mountpoint=$OPTARG
	;;
    r)  restore=1
	;;
    ?)	exit 1
	;;
    esac
done





# Exit codes for s3ql mount documented in rst/man/mount.rst
# Exit codes for s3ql fsck documented in rst/man/fsck.rst
# Additional:
#  70 : No valid backend specified
#  71 : No suitable target
#  75 : Missing filesystem during restore
#  90 : Missing 'bucket' for s3 backend
#

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

# find out if there is a mounted backend
curr_backend=$(sed -n "s%\(\w*\)://.*\s${mountpoint}.*%\1% p" /proc/mounts)
if [ ! -z $curr_backend ]; then
	echo "Existing backend: $curr_backend"
	echo "Configured backend: $backend"
	if [[ $backend != "${curr_backend}://" ]] ; then
		echo "Backend changed, unmount current"
		fusermount -u ${mountpoint}
	else
		echo "Current backend valid"
	fi
else
	echo "No current backend"
fi

# Backup destination  (storage url)
#echo "Backend: $backend"
if [[ $backend == *local* ]]; then
	device=$(sed -n "s%\(/dev/sd\w*\)\s${backupdisk}.*%\1% p" /proc/mounts)
	echo "Device $device"
	if [ ! -z $device ]; then
		if [ -b $device ] ; then
			# the mountpoint exists and so does the device, lets use it.
			echo "Usable device found"
			mkdir -p ${backupdisk}/opi-backup
			storage_url="${backend}/${backupdisk}/opi-backup"
		else
			echo "The mounted device does not exist, unmount"
			umount $device
			fusermount -u $mountpoint
		fi
	fi
	if [ -z $storage_url ]; then	
		# there is no suitable device mounted
		
		# create mountpoint for disk
		mkdir -p $backupdisk
		
		for device in ${backupdevice}; do
			echo "Device: $device, try to mount it"
			if [ -b $device ] && mount $device $backupdisk ; then
				echo "Device $device mounted"
				mkdir -p ${backupdisk}/opi-backup
				storage_url="${backend}/${backupdisk}/opi-backup"
				break
			fi
		done
	fi
elif [[ $backend == *s3op://* ]]; then
	echo "Using: $backend"
	storage_url="${backend}${storage_server}/${unit_id}"
	CA="--backend-options ssl-ca-path=${ca_path}"

elif [[ $backend == *s3://* ]]; then
	echo "Using: $backend"
	if [ -z "$bucket" ]; then
		echo "Missing bucket"
		exit 90
	else		
		storage_url="${backend}${bucket}/"
		CA=""
	fi
else
	echo "No valid backend"
	exit 70
fi

if [ -z $storage_url ]; then
	echo "No suitable device found for backup target, exiting"
	exit 71	
fi

# Test if s3ql filesystem is mounted

if grep -qs "${mountpoint} " /proc/mounts; then
	if [ -z "$(pgrep 'mount.s3ql')" ]; then
		# s3ql is not running
		echo "S3QL not running, umount"
		fs_mounted=0
		umount $mountpoint
	else
	#	echo "Filesystem mounted"
		fs_mounted=1
	fi
else
	fs_mounted=0
fi

# Abort entire script if any command fails
set -e

# create dir tree
if [ ! -d $mountpoint ]; then
	echo "Create mountpoint"
	mkdir -p $mountpoint
fi

# Create cache dir
mkdir -p $s3ql_cachedir

if [ $fs_mounted -eq 0 ]; then
	# remove any old symlinks
	if [[ -d "$owncloud_dir" ]]; then
		echo "Removing symlinks"
		cd $owncloud_dir
		for dir in */ ; do
			#echo "DIR: $dir"
	    		if [[ -d "${dir}/files/backup" ]]; then
				#echo "Removing symlink to backupdir '$dir/files/backup'."
				rm -rf "${dir}/files/backup"
			fi
		done
	fi
	# Recover cache if e.g. system was shut down while fs was mounted
	echo "Start fsck"
	set +e
	#echo "${s3ql_path}fsck.s3ql ${CA} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  $storage_url"
	fsck_result=$(${s3ql_path}fsck.s3ql ${CA} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  "$storage_url")
	retval=$?
	set -e
	if [[ $retval -ne 0 ]];
	then
		if [[ $retval -eq 18 ]] # No S3QL filesystem found
		then
			if [ $restore -eq 1 ]; then
				echo "No filesystem found on device"
				exit 75
			fi
			echo "Creating filesystem"
			${s3ql_path}mkfs.s3ql ${CA} --cachedir ${s3ql_cachedir} --authfile ${auth_file}  "$storage_url"
			echo "Finished creating filesystem"
		elif [[ $retval -eq 128 ]] # Recoverable error, warn but do nothing.
		then
			echo "WARN, recoverable error was encountered"
		else
			echo "fsck returned unexpected result: $retval"
			exit $retval
		fi

	fi
	# Not mounted, then mount file system
	echo "Mount filesystem"
	${s3ql_path}mount.s3ql --allow-other ${CA} --quiet --cachedir ${s3ql_cachedir} --cachesize ${s3ql_cachesize} --log $log_file --authfile ${auth_file} "$storage_url" "$mountpoint"
fi
mount_val=$?
exit $mount_val

