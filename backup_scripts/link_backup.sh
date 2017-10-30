#!/bin/bash

src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source mount_fs.sh

# Find the existing backup dates
for version in "${!valid_backends[@]}"
do
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
		users=""
		for user in */; do
			if [ -d "${user}/files/backup" ]; then
				find -L "${user}/files/backup" -type l -delete
				#echo "Removing links to expired backups for '$user'"
			fi
			if [ -d "${nextcloud_dir}/$user/files" ]; then
				# remove trailing "/" from username
				uname=${user::-1}
				users="$users $uname"
				
				
				echo "Creating links for user: '$uname'"
				mkdir -p "${nextcloud_dir}/$user/files/backup/"
				for date in "${dates[@]}"; do
					#echo "link target: ${mountpoint}/${date}/${userdata}/${user}"
					if [ -d ${mountpoints[$version]}/${date}/${userdata}/${user} ]; then 
						if [ ! -L "${nextcloud_dir}/$user/files/backup/${date}" ]; then
							debug "Creating link to ${date} for $user"
							ln -s "${mountpoints[$version]}/${date}/${userdata}/${user}/files" "${nextcloud_dir}/$user/files/backup/${date}"
						#else
							#echo "link present"
						fi
					fi
				done
			else
				debug "User $user not existing, skipping..."
			fi
		done
		for user in $users; do
			debug "Trigger nextcloud scan for '$user'"
			cd ${nextcloud_installdir}
			su -s /bin/sh -c "php ./occ files:scan -v -- ${uname}" www-data
			if [ $? -ne 0 ]; then
				echo "File scan for user '$uname' failed"
			fi
		done
		
	fi
done
