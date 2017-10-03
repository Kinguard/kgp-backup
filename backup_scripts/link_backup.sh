#!/bin/bash

DIR=$(dirname "${BASH_SOURCE[0]}")
cd $DIR
pwd

source mount_fs.sh

# Find the existing backup dates
for version in "${versions[@]}"
do
	if [[ ${valid_fs[$version]} -eq 0 || ${valid_fs[$version]} -eq 128 ]]; then
		if [[ -e ${mountpoints[$version]} ]]; then
			echo "Create backup links for '$version'"
			cd ${mountpoints[$version]}
			dates=()
			for dir in */ ; do
				if [ $dir != "lost+found/" ]; then
					#echo "Backup date: $dir"
					date="${dir%/}"
					dates+=($date)	
				fi
			done
			#echo ${dates[@]}

			cd $nextcloud_dir
			echo "Creating backup structure"
			# remove any symlinks that are not present in the backup

			cd $nextcloud_dir
			for user in */; do
				if [ -d "${user}/files/backup" ]; then
					find -L "${user}/files/backup" -type l -delete
					#echo "Removing links to expired backups for '$user'"
				fi
				if [ -d "${nextcloud_dir}/$user/files" ]; then
					mkdir -p "${nextcloud_dir}/$user/files/backup/"
					for date in "${dates[@]}"; do
						#echo "link target: ${mountpoint}/${date}/${userdata}/${user}"
						if [ -d ${mountpoints[$version]}/${date}/${userdata}/${user} ]; then 
							if [ ! -L "${nextcloud_dir}/$user/files/backup/${date}" ]; then
								echo "Creating link to ${date} for $user"
								ln -s "${mountpoints[$version]}/${date}/${userdata}/${user}/files" "${nextcloud_dir}/$user/files/backup/${date}"
							#else
								#echo "link present"
							fi
						fi
					done
				else
					echo "User $user not existing, skipping..."
				fi
			done
		fi
	fi
done