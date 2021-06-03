#!/bin/bash

#
# s3ql_backup.sh
#
# Performs a backup on a (fuse) mounted s3ql fs
#
#

src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

function state_update {
	if [[ -z "$state" ]]; then
		state=1
	else
		state=$((state + 1))
	fi
	echo $1
	echo '{"state":"'$state'", "desc":"'$1'","max_states":"'$max_states'"}' > $statefile
}

function path2ver {
	local mntpath=$1
	binpath=$(ps ax | grep $mntpath | grep -v 'grep' | awk '{print $6}')
	for version in ${!s3qlpath[@]}
	do
		if [[ "$binpath" == "${s3qlpath[$version]}mount.s3ql" ]]; then
			echo "$version"
			return 0
		fi
	done
	return 1
}

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.
# cmd-line overrides config file parameters.
while getopts "pd" opt; do
    case "$opt" in
    d)  DEBUG=1
        ;;
    p)  
        # do not use any colors in output
        plaintext=1
        ;;
    *)	exit 1
	   ;;
    esac
done


new_backup="inprogress"
this_backup=`date "+%Y-%m-%d_%H:%M:%S"`

if [ ! -d $logdir ]; then
	mkdir $logdir
fi

if [ ! -d "$logdir/errors" ]; then
	mkdir "$logdir/errors"
fi
if [ ! -d "$logdir/complete" ]; then
	mkdir "$logdir/complete"
fi

echo "Backup started. This file shall be removed upon completion of the backup job." > "${logdir}/errors/$this_backup"
echo "If the job is still running, this file is also present." >> "${logdir}/errors/$this_backup"
state_update "Backup started"

# mount_fs.sh also includes backup.lib.sh where a bunch of useful defines and functions lives.
source mount_fs.sh
echo "Mount complete"

# Abort entire script if any command fails
set -e


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
		echo "Insufficient space on target '$bytes_used' vs $quota"
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
echo "Removing any interrupted old data..."
rm -rf $new_backup

state_update "Duplicate backup"
if [ -n "$last_backup" ]; then
    echo "Copying $last_backup to '$new_backup'..."
    sudo ${PYPATH[$CURRENT_VERSION]}${s3qlpath[$CURRENT_VERSION]}s3qlcp "$last_backup" "$new_backup"

else
	# Check if dirs exist on backup target
	if [ ! -d $new_backup ]; then
		echo "No backupdir present, creating $new_backup"
		mkdir -p $new_backup
	fi

fi

version=$(dpkg -s opi-backup | sed -n 's/Version:\s*\([0-9\.]*\)/\1/p')

# write temporary "fail" status msg
echo '{"date":"'$this_backup'", "status":"fail", "script_version":"'$version'"}' > ./${new_backup}/status.json

# ..and update the copy
state_update "Copy user files"

echo "Calculating user excluded files"
excludelist=$(mktemp -t excludelist.XXXX)
echo "Exclude file: $excludelist"
find "${nextcloud_dir}" -name $excludepattern -exec dirname {} >> $excludelist \;
sed -i s%${nextcloud_dir}%% $excludelist

echo "Excluded files:"
cat $excludelist
echo "---  End list ---"

echo "Starting data sync"
set +e

rsync -aHAXxPh --delete-during --delete-excluded --partial --info=progress2 \
	--exclude-from=$excludelist \
    --exclude "*/cache/" \
    --exclude "*/gallery/" \
    --exclude "*/files/backup" \
    --exclude "*/files_versions" \
    --exclude "appdata_oc*" \
    --exclude "*/files_trashbin" \
    "${nextcloud_dir}" "./${new_backup}/${userdata}" > ${progressfile}

rsync_user=$?
echo "RSYNC user: $rsync_user"
rm $excludelist
rm $progressfile


state_update "Copy calendars and contacts"

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


state_update "Copy mail and system files (/etc/)"
if [[ ! -d "./${new_backup}/${systemdir}/etc/opi" ]]; then
	mkdir -p ./${new_backup}/${systemdir}/etc/opi
	chmod 755 ./${new_backup}/${systemdir}/etc/opi
fi

sysfiles="
/etc/opi/opi-access.conf 
/etc/opi/opi-update.conf 
/etc/opi/signed_certs 
/etc/opi/sysinfo.conf 
/etc/opi/web_cert.pem 
/etc/opi/web_key.pem 
/etc/opi/org_cert.pem 
/etc/opi/org_key.pem
"
for file in $sysfiles
do
	if [[ -e $file ]]; then
		sys_filelist="$sys_filelist $file"
	fi
done

rsync -qaHAXx --delete-during --delete-excluded --partial --info=progress2\
	$sys_filelist \
    "./${new_backup}/${systemdir}/etc/opi"  > ${progressfile}

rsync_etc=$?
echo "RSYNC /etc/opi: $rsync_etc"


echo "Copy system files (/var/opi/ + misc)"
rsync -qaHAXx --delete-during --delete-excluded --partial --info=progress2\
    --exclude "nextcloud/data" \
    --exclude "etc/backup/.s3ql_cache" \
    --exclude "mysql" \
    --exclude "tmp" \
    "/var/opi" \
    "/usr/share/nextcloud/config/config.php" \
    "/etc/postfix/main.cf" "/etc/mailname" \
    "/etc/shadow" \
    "./${new_backup}/${systemdir}"  > ${progressfile}

rsync_system=$?
echo "RSYNC system: $rsync_system"



echo "Copy kinguard files (/etc/kinguard/)"

rsync -qaHAXx --delete-during --delete-excluded --partial --info=progress2\
    "/etc/kinguard" \
    "./${new_backup}/${systemdir}/etc/"  > ${progressfile}

rsync_system=$?
echo "RSYNC system: $rsync_system"



if [ $rsync_user -ne 0 ] || [ $rsync_system -ne 0 ] || [ $rsync_etc -ne 0 ]; then
	if [ $rsync_user -eq 24 ] || [ $rsync_system -eq 24 ]; then
		# this is the case when files have dissappeard, that is ok since user files can do that, epecially mail
		rsync_retval=0
		echo "rsync lost some files on the way"
	else
		let "rsync_retval=$rsync_user+$rsync_system+$rsync_etc"		#return something that maybe can be useful...
		echo "RSYNC RetVal: $rsync_retval"
	fi
else
	rsync_retval=0
fi
set -e

state_update "Dump SQL database"
/usr/bin/mysqldump -uroot -p${mysql_pwd} --all-databases > "./${new_backup}/${systemdir}/opi.sql"

# Change ownership and set access rights
state_update "Setting file permissions"

echo "Change ownership"
chown -R root:www-data "./${new_backup}/${userdata}"

# This is needed to allow access to directories in backup #556
find "./${new_backup}/${userdata}/" -type d -exec chmod g+r+x {} \;

# write "success" status msg
echo '{"date":"'$this_backup'", "status":"ok", "script_version":"'$version'"}' > ./${new_backup}/status.json

# rename backup
mv ${new_backup} $this_backup

echo "Making backup immutable"
${s3ql_path}s3qllock "$this_backup"

rm "${logdir}/errors/$this_backup"

echo "Remove old logfiles"
# keep newest file, remove the rest
cd "${logdir}/errors/"
pwd
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

echo "Backup finished to '${backend_text}' without errors" > "${logdir}/complete/$this_backup"
echo "Last backup to: '$backend_text'" > "${logdir}/complete/last_target"
echo "Backup finished"

cd ${mountpoints[$CURRENT_VERSION]}
state_update "Remove old backups"
# Expire old backups

for mount in "${!valid_backends[@]}"
do
	mntpath=${valid_backends[$mount]}
	cd ${mntpath}
	echo "Expire backups for '$mount' ('$mntpath')"

	version=$(path2ver $mntpath)
	echo "Using version '$version'"
	echo "Check state file status"
	sudo $DIR/expire.py -d --s3ql ${mntpath}
	echo "Syncing filesystem"
	sudo ${PYPATH[$version]}${s3qlpath[$version]}s3qlctrl flushcache ${mountpoints[$version]}
done

echo "Exit with '$rsync_retval'"
exit $rsync_retval
