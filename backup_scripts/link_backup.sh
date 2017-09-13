#!/bin/bash
source /usr/share/opi-backup/mount_fs.sh


# Find the existing backup dates
cd $backup_mntpoint
dates=()
for dir in */ ; do
	if [ $dir != "lost+found/" ]; then
		#echo "Backup date: $dir"
		date="${dir%/}"
		dates+=($date)	
	fi
done
#echo ${dates[@]}

cd $owncloud_dir
echo "Creating backup structure"
# remove any symlinks that are not present in the backup

cd $owncloud_dir
for user in */; do
	if [ -d "${user}/files/backup" ]; then
		find -L "${user}/files/backup" -type l -delete
		#echo "Removing links to expired backups for '$user'"
	fi
	if [ -d "${owncloud_dir}/$user/files" ]; then
		mkdir -p "${owncloud_dir}/$user/files/backup/"
		for date in "${dates[@]}"; do
			#echo "link target: ${backup_mntpoint}/${date}/${userdata}/${user}"
			if [ -d ${backup_mntpoint}/${date}/${userdata}/${user} ]; then 
				if [ ! -L "${owncloud_dir}/$user/files/backup/${date}" ]; then
					echo "Creating link to ${date} for $user"
					ln -s "${backup_mntpoint}/${date}/${userdata}/${user}/files" "${owncloud_dir}/$user/files/backup/${date}"
				#else
					#echo "link present"
				fi
			fi
		done
	else
		echo "User $user not existing, skipping..."
	fi
done

