#!/bin/bash
source /etc/opi/sysinfo.conf
source /etc/opi/backup.conf

# Backup destination  (storage url)
storage_url="${backend}/${unit_id}"

# Test if filesystem is mounted

if grep -qs "$mountpoint" /proc/mounts; then
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
	fsck_result=$(${s3ql_path}fsck.s3ql --ssl-ca-path ${capath} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  "$storage_url")
	set -e
	#echo "FSCK result: $fsck_result, exit code $?"
	if [[ $fsck_result == *'No S3QL file system found'* ]] && [[ $? -eq 0 ]]
	then
		echo "Creating filesystem";
		${s3ql_path}mkfs.s3ql --ssl-ca-path ${capath} --cachedir ${s3ql_cachedir} --authfile ${auth_file}  "$storage_url"
		echo "Finished creating filesystem"
	fi
	# Not mounted, then mount file system
	echo "Mount filesystem"
	${s3ql_path}mount.s3ql --allow-other --ssl-ca-path ${capath} --quiet --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file} "$storage_url" "$mountpoint"
fi

