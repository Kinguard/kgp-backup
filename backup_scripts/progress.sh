#!/bin/bash
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

status=0
if [[ -e $progressfile ]];then

	readarray -t result <<< "$(tail -n 2 $progressfile)"

	filename=${result[0]}
	IFS=$'\r' read -ra lines <<< "${result[1]}"
	line=${lines[-1]}

	# Sets data
	# $1 => transfered
	# $2 => progress in %
	# $3 => rate
	# $4 => eta
	set $line
	transfered=$1
	progress=$2
	rate=$3
	eta=$4
fi

# Simple check that we at lease have 4 elements....
# also check that the filename is valid.
if [[ -z "$eta" ]] && [[ -e $filename ]]; then
	echo '{"status":"0", "filename":"", "progress":"0", "eta":"", "rate":"", "transfered":""}'
else
	echo '{"status":"1", "filename":"'$filename'", "progress":"'$progress'", "eta":"'$eta'", "rate":"'$rate'", "transfered":"'$transfered'"}'
fi
