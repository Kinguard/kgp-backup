#!/bin/bash
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

status=0
if [[ -e $progressfile ]];then
	output=$(tail -n 2 /tmp/opi-backup.progress)
	readarray -t result <<<"$output"
	#IFS=$'\n' progress=($output)

	filename=${result[0]}
	progress_combined=${result[1]}

	#echo "Progress: ${progress[1]##*              }"
	progress=($(echo "$progress_combined" | sed -n -e 's/\s*\([0-9a-zA-Z\.]\+\)\s\+\([0-9]\+\%\)\s*\([a-zA-Z0-9\/\.]\+\)\s*\([a-zA-Z0-9:]\+\) (xfr.*$/\1 \2 \3 \4 / p '))
	if [[ ! -z "${progress[3]}" ]]; then
		#managed to parse the output, total time is not empty
		status=1
	fi
fi

if [[ $status -eq 0 ]]; then
	echo '{"status":"'$status'", filename":"", "progress":"0", "elapsed-time":"", "rate":"", "transfered":""}'
else
	echo '{"status":"'$status'", filename":"'$filename'", "progress":"'${progress[1]}'", "elapsed-time":"'${progress[3]}'", "rate":"'${progress[2]}'", "transfered":"'${progress[0]}'"}'
fi
