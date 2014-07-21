#!/bin/bash
source /etc/opi/sysinfo.conf
source /etc/opi/backup.conf
source ${backupbin_path}./mount_fs.sh

new_backup=`date "+%Y-%m-%d_%H:%M:%S"`


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
echo "Backup started. This file shall be removed upon completion of the backup job." > "${logdir}/errors/$new_backup"
echo "If the job is still running, this file is also present." >> "${logdir}/errors/$new_backup"


if [[ $backend == *'s3op'* ]]; then
	#Get the quota and bytes used from storage server
	IFS='%'
	while read -r line; do
		declare $line
	done < <(${backupbin_path}/get_quota.py -t sh)
	unset IFS
	if [ ! $Code ]; then
		echo "Unknown response from server, exiting"
		exit 1
else
		if [ $Code != "200" ]; then
			if [[ -z "$message" ]]; then
				echo "Server responded with code $Code"
			else
				echo "$message"
		fi
			exit 1
		fi
fi

	if [ $bytes_used -gt $quota ]; then
		echo "Insufficient space on target"
		exit 1
	fi
else
	echo "OP backend not used"
fi


# Make sure the file system is unmounted when we are done
#trap "cd /; ${s3ql_path}umount.s3ql '$mountpoint'; rm -rf '$mountpoint'; echo $?" EXIT

# Figure out the most recent backup
cd "$mountpoint"

last_backup=`python3 <<EOF
import os
import re
backups=sorted(x for x in os.listdir('.') if re.match(r'^[\\d-]{10}_[\\d:]{8}$', x))
if backups:
    print(backups[-1])
EOF`

# Duplicate the most recent backup unless this is the first backup
echo "Duplicate backup"
if [ -n "$last_backup" ]; then
    echo "Copying $last_backup to $new_backup..."
    ${s3ql_path}s3qlcp "$last_backup" "$new_backup"

    # Make the last backup immutable
    # (in case the previous backup was interrupted prematurely)
    # ${s3ql_path}s3qllock "$last_backup"
else
	# Check if dirs exist on backup target
	if [ ! -d $new_backup ]; then
		echo "No backupdir present, creating $new_backup"
		mkdir $new_backup
	fi
	if [ ! -d "${new_backup}/${systemdir}" ]; then
		echo "System dir not present, creating"
		mkdir "${new_backup}/${systemdir}"
	fi
	# userdata dir will be created by rsync below
fi



# ..and update the copy
echo "Update copy"

rsync -aHAXx --delete-during --delete-excluded --partial -v \
    --exclude "*/cache/" \
    --exclude "*/gallery/" \
    --exclude "*/files/backup" \
    "${owncloud_dir}" "./${new_backup}/${userdata}"

echo "Dump SQL database"
/usr/bin/mysqldump -uroot -p${mysql_pwd} --all-databases > "./${new_backup}/${systemdir}/opi.sql"

# Make the new backup immutable
# ${s3ql_path}s3qllock "$new_backup"

# Change ownership and set access rights
echo "Change ownership"
chown -R root:www-data "./${new_backup}"
chown -R root:root "./${new_backup}/${systemdir}"

# Set directories to read and excute for group
# and files to read only
echo "Set permissions on user files"
find "./${new_backup}" -type d -print0 | xargs -0 chmod 770 
find "./${new_backup}" -type f -print0 | xargs -0 chmod 640

# only allow root access to system files
echo "Set permissions on system files"
find "./${new_backup}/${systemdir}" -type d -print0 | xargs -0 chmod 700 
find "./${new_backup}/${systemdir}" -type f -print0 | xargs -0 chmod 600

rm "${logdir}/errors/$new_backup"

echo "Remove old logfiles"
# keep newest file, remove the rest
cd "${logdir}/errors/"
nbr_files=$(ls -1 | wc -l)
if [ "$nbr_files" -gt 1 ]; then
	ls -tr | head -n -1 | xargs rm
fi

# keep newest 4 files, remove the rest
cd "${logdir}/complete/"
nbr_files=$(ls -1 | wc -l)
if [ "$nbr_files" -gt 4 ]; then
	ls -tr | head -n -4 | xargs rm
fi

echo "Backup finished without errors" > "${logdir}/complete/$new_backup"
echo "Backup finished"

cd "$mountpoint"
echo "Expire backups"
# Expire old backups

# Note that expire_backups.py comes from contrib/ and is not installed
# by default when you install from the source tarball. If you have
# installed an S3QL package for your distribution, this script *may*
# be installed, and it *may* also not have the .py ending.
#${s3ql_contrib}expire_backups.py --use-s3qlrm 1 7 14 31 90 180 360
${s3ql_contrib}expire_backups.py --reconstruct-state 1 7 14 31 90 180 360

echo "Syncing filesystem"
${s3ql_path}s3qlctrl flushcache $mountpoint

