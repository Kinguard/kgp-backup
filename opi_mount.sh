#!/bin/bash
source /etc/opi/sysinfo.conf
source /etc/opi/backup.conf

# Backup destination  (storage url)
storage_url="${backend}/${unit_id}"


if [ ! -d $logdir ]; then
	mkdir $logdir
fi

if [ ! -d "$logdir/errors" ]; then
	mkdir "$logdir/errors"
fi
if [ ! -d "$logdir/complete" ]; then
	mkdir "$logdir/complete"
fi


# Abort entire script if any command fails
set -e

# create dir tree, no error if existing
mkdir -p $mountpoint

# Create cache dir
mkdir -p $s3ql_cachedir

# Test that the filesystem is mounted
if grep -qs "$mountpoint" /proc/mounts; then
	echo "Filesystem already mounted"
else
	# remove any old symlinks
	cd $owncloud_dir
	for dir in */ ; do
		echo "DIR: $dir"
    		if [[ -L "${dir}/files/backup" ]]; then
			echo "Removing symlink to backupdir '$dir/files/backup'."
			rm -rf "${dir}/files/backup"
		fi
	done
	# Recover cache if e.g. system was shut down while fs was mounted
	${s3ql_path}fsck.s3ql --ssl-ca-path ${capath} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  "$storage_url"

	# Not mounted, then mount file system
	echo "Mount filesystem"
	${s3ql_path}mount.s3ql --allow-other --ssl-ca-path ${capath} --quiet --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file} "$storage_url" "$mountpoint"
fi

# remove any old links
cd $owncloud_dir
sys_users=()
for dir in */ ; do
	#echo "System user: $dir"
	sys_users+=($dir)
	if [[ -d "${dir}/files/backup" ]]; then
		echo "Removing backupdir structure '$dir/files/backup'."
		rm -rf "${dir}/files/backup"
	fi
done


# Find the existing backup dates
cd $backup_mntpoint
dates=()
for dir in */ ; do
	if [ $dir != "lost+found/" ]; then
		echo "Backup date: $dir"
		date="${dir%/}"
		dates+=($date)	
	fi
done
#echo ${dates[@]}

for user in "${sys_users[@]}"; do
	echo "Sys user: $user"
	if [ -d "${owncloud_dir}/$user/files" ]; then
		echo "Creating backup structure"
		mkdir -p "${owncloud_dir}/$user/files/backup/"
		for date in "${dates[@]}"; do
			echo "link target: ${backup_mntpoint}/${date}/${userdata}/${user}"
			if [ -d ${backup_mntpoint}/${date}/${userdata}/${user} ]; then 
				echo "Creating link to ${date}"
				ln -s "${backup_mntpoint}/${date}/${userdata}/${user}/files" "${owncloud_dir}/$user/files/backup/${date}"
			fi
		done
	else
		echo "User $user not existing, skipping..."
	fi
done

