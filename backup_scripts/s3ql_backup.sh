#!/bin/bash
source /etc/opi/sysinfo.conf

cd $(dirname "${BASH_SOURCE[0]}")
# mounnt_fs.sh also includes backup.lib.sh where a bunch of useful defines and functinos lives.
source mount_fs.sh
echo "Mount complete"

new_backup=`date "+%Y-%m-%d_%H:%M:%S"`

#set -x

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

if [[ $backend == "s3op://" ]]; then
	backend_text="OpenProducts"
	#Get the quota and bytes used from storage server
	IFS='%'
	while read -r line; do
		declare $line
	done < <(./get_quota.py -t sh)
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
	#echo "OP backend not used"
	if [[ $backend == "s3://" ]]; then
		backend_text="Amazon"
	elif [[ $backend == "local://" ]]; then
		backend_text="Local target"
	else
		backend_text="Unknown"
	fi
fi

# Figure out the most recent backup
cd ${mountpoints[$CURRENT_VERSION]}

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
    sudo ${PYPATH[$CURRENT_VERSION]}${s3qlpath[$CURRENT_VERSION]}s3qlcp "$last_backup" "$new_backup"

    # Make the last backup immutable
    # (in case the previous backup was interrupted prematurely)
    # ${s3ql_path}s3qllock "$last_backup"
else
	# Check if dirs exist on backup target
	if [ ! -d $new_backup ]; then
		echo "No backupdir present, creating $new_backup"
		mkdir $new_backup
	fi

	#if [ ! -d "${new_backup}/${systemdir}" ]; then
	#	echo "System dir not present, creating"
	#	mkdir "${new_backup}/${systemdir}"
	#fi
	# userdata dir will be created by rsync below
fi

script_version=$(dpkg -s opi-backup | sed -n 's/Version:\s*\([0-9\.]*\)/\1/p')
echo "Version: $script_version"
nbr_dots=$(grep -o "\." <<< "$script_version" | wc -l)
if [ $nbr_dots -gt 1 ]; then
	echo "WARN: Only one level of minor number is supported, version number is not to be trusted."
	version=$script_version
	
else
	major=$(echo $script_version | sed -n 's/\([0-9]*\)\.[0-9]*/\1/p')
	minor=$(echo $script_version | sed -n 's/[0-9]*\.\([0-9]*\)/\1/p')
	version=$((major*1000+$((minor)) ))
fi

# write temporary "fail" status msg
echo '{"date":"'$new_backup'", "status":"fail", "script_version":"'$version'"}' > ./${new_backup}/status.json


# ..and update the copy
echo "Copy user files"

set +e
rsync -qaHAXx --delete-during --delete-excluded --partial \
    --exclude "*/cache/" \
    --exclude "*/gallery/" \
    --exclude "*/files/backup" \
    "${nextcloud_dir}" "./${new_backup}/${userdata}"

rsync_user=$?
echo "RSYNC user: $rsync_user"

echo "Copy calendars and contacts"
calendarexport="/usr/share/nextcloud/calendars_export.php"
if [[ -e $calendarexport ]]; then
	php "$calendarexport" "./${new_backup}/${userdata}"
else
	echo "Missing Calendar Export Script"
fi

contactsexport="/usr/share/nextcloud/contacts_export.php"
if [[ -e $contactsexport ]]; then
	php "$contactsexport" "./${new_backup}/${userdata}"
else
	echo "Missing Contacts Export Script"
fi

echo "Copy system files"
rsync -qaHAXx --delete-during --delete-excluded --partial \
    --exclude $nextcloud_dir \
    --exclude "mysql" \
    "/var/opi" \
    "/usr/share/nextcloud/config/config.php" \
    "/etc/postfix/main.cf" "/etc/mailname" \
    "/etc/shadow" \
    "/etc/opi" \
    "./${new_backup}/${systemdir}"

rsync_system=$?
echo "RSYNC system: $rsync_system"

if [ $rsync_user -ne 0 ] || [ $rsync_system -ne 0 ]; then
	if [ $rsync_user -eq 24 ] || [ $rsync_system -eq 24 ]; then
		# this is the case when files have dissappeard, that is ok since user files can do that, epecially mail
		rsync_retval=0
		echo "rsync lost some files on the way"
	else
		let "rsync_retval=$rsync_user+$rsync_system"		#return something that maybe can be useful...
		echo "RSYNC RetVal: $rsync_retval"
	fi
fi
set -e

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
find "./${new_backup}" -type d -print0 | xargs -0 chmod 750 
find "./${new_backup}" -type f -print0 | xargs -r0 chmod 640  # there might not be any user files

# only allow root access to system files
echo "Set permissions on system files"
find "./${new_backup}/${systemdir}" -type d -print0 | xargs -0 chmod 700 
find "./${new_backup}/${systemdir}" -type f -print0 | xargs -r0 chmod 600

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

echo "Backup finished to '${backend_text}' without errors" > "${logdir}/complete/$new_backup"
echo "Last backup to: '$backend_text'" > "${logdir}/complete/last_target"
echo "Backup finished"

cd ${mountpoints[$CURRENT_VERSION]}
# write "success" status msg
echo '{"date":"'$new_backup'", "status":"ok", "script_version":"'$version'"}' > ./${new_backup}/status.json
echo "Expire backups"
# Expire old backups


for version in "${versions[@]}"
do
	if [[ ${valid_fs[$version]} -eq 0 || ${valid_fs[$version]} -eq 128 ]]; then
		if [[ -e ${mountpoints[$version]} ]]; then
			echo "Expire backups for version '$version'"
			cd ${mountpoints[$version]}
			sudo ${PYPATH[$version]}${s3qlpath[$version]}expire_backups --use-s3qlrm --reconstruct-state 1 7 14 31 90 180 360
			#case $version in
			#	"v2_21")
			#		expire_backups --use-s3qlrm --reconstruct-state 1 7 14 31 90 180 360
			#		;;
			#	*)
			#		${PYPATH[$version]} expire_backups --reconstruct-state 1 7 14 31 90 180 360
			#		;;
			#esac
			echo "Syncing filesystem"
			sudo ${PYPATH[$version]}${s3qlpath[$version]}s3qlctrl flushcache ${mountpoints[$version]}
		else
			echo "No legacy backups mounted"
		fi
	fi
done

echo "Exit with '$rsync_retval'"
exit $rsync_retval
