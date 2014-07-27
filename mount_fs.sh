#!/bin/bash

cd $(dirname "${BASH_SOURCE[0]}")
source backup.conf
source /etc/opi/sysinfo.conf

if [ -e $target_file ]; then
	source  $target_file
else
	echo "Using default backend"
	backend="s3op://" # set default
fi
#set -x


# Backup destination  (storage url)
echo "Backend: $backend"
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
		
		for device in /dev/sd*; do
			echo "Device: $device, try to mount it"
			if [ -b $device ] && mount $device $backupdisk ; then
				echo "Device $device mounted"
				mkdir -p ${backupdisk}/opi-backup
				storage_url="${backend}/${backupdisk}/opi-backup"
				break
			fi
		done
	fi
else
	storage_url="${backend}${storage_server}/${unit_id}"
fi
if [ -z $storage_url ]; then
	echo "No suitable device found for backup target, exiting"
	exit 1	
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
	echo "Removing symlinks"
	cd $owncloud_dir
	for dir in */ ; do
		#echo "DIR: $dir"
    		if [[ -d "${dir}/files/backup" ]]; then
			#echo "Removing symlink to backupdir '$dir/files/backup'."
			rm -rf "${dir}/files/backup"
		fi
	done
	# Recover cache if e.g. system was shut down while fs was mounted
	echo "Start fsck"
	set +e
	fsck_result=$(${s3ql_path}fsck.s3ql --ssl-ca-path ${ca_path} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  "$storage_url")
	set -e
	#echo "FSCK result: $fsck_result, exit code $?"
	if [[ $fsck_result == *'No S3QL file system found'* ]] && [[ $? -eq 0 ]]
	then
		echo "Creating filesystem";
		${s3ql_path}mkfs.s3ql --ssl-ca-path ${ca_path} --cachedir ${s3ql_cachedir} --authfile ${auth_file}  "$storage_url"
		echo "Finished creating filesystem"
	fi
	# Not mounted, then mount file system
	echo "Mount filesystem"
	${s3ql_path}mount.s3ql --allow-other --ssl-ca-path ${ca_path} --quiet --cachedir ${s3ql_cachedir} --cachesize ${s3ql_cachesize} --log $log_file --authfile ${auth_file} "$storage_url" "$mountpoint"
fi

