#!/bin/bash

cd $(dirname "${BASH_SOURCE[0]}")
source backup.conf
source backup.lib.sh

if [ -e $target_file ]; then
	source  $target_file
else
	echo "Using default backend"
	backend="s3op://" # set default
fi

DEBUG=1

# find out if there is a mounted backend
declare -A valid_backends
# this will populate the above "valid_backends"
get_valid_backends $backend
status=0
if [[ ${#valid_backends[@]} -gt 0 ]]; then
	for mount in "${!valid_backends[@]}"
	do
		debug "Umount backend: '$mount' from '${valid_backends[$mount]}'"
		sudo fusermount -u ${valid_backends[$mount]}
		status=$?
		debug "Umount status: '$status'"
	done
	debug "Kill all remaining s3ql processes"
	s3ql_kill
	
    echo "Remove any existing old symlinks"
    removelinks $nextcloud_dir
    retval=$1
    if [[ $retval -ne $PASS ]]; then
    	debug "Failed to remove symlinks"
    fi


else
	debug "No valid backends"
	status=0
fi

exit $status
