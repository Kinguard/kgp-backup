#!/bin/bash

cd $(dirname "${BASH_SOURCE[0]}")
source backup.conf
source /etc/opi/sysinfo.conf

if [ -e $target_file ]; then
	source  $target_file
else
	echo "Using default backend"
	backend="s3op://" # set default
fi
#set -x

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
restore=0

while getopts "m:" opt; do
    case "$opt" in
    m)  mountpoint=${OPTARG%/}
	;;
    ?)	exit 1
	;;
    esac
done

shift $((OPTIND-1))

[ "$1" = "--" ] && shift

#echo "auth_file=$auth_file, backend=$backend, mountpoint='$mountpoint' Leftovers: $@"

#exit 1


# find out if there is a mounted backend
echo "Mountpoint: '$mountpoint'" 
curr_backend=$(sed -n "s%\(\w*\)://.*\s${mountpoint}.*%\1% p" /proc/mounts)
echo "Current backend: $curr_backend"
if [ ! -z $curr_backend ]; then
	echo "Unmounting backend '$curr_backend' on '$mountpoint'"
	fusermount -u ${mountpoint}
else
	echo "Nothing mounted on '$mountpoint'"
fi

