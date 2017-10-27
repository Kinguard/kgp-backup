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
	for version in "${!valid_backends[@]}"
	do
		debug "Umount backend: '${valid_backends[$version]}'  version: $version Path: '${mountpoints[$version]}'"
		sudo ${PYPATH[$version]}${s3qlpath[$version]}umount.s3ql ${mountpoints[$version]}
		status=$?
		debug "Umount status: '$status'"
	done
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
