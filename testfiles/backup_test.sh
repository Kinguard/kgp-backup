#!/bin/bash
#set -x


read -p "This will likely corrupt any already setup backup configs, Continue? [n/Y] " answer
if [[ $answer != "Y" && $answer != "" ]]; then
	echo "Quitting."
	exit 1
fi
echo ""

if [[ $1 == "-a" ]]; then
	echo "Running full tests"
fi

DIR=$(dirname "${BASH_SOURCE[0]}")
cd $DIR

#read configs
source ../backup_scripts/backup.conf
# read the file with all the fun in it...
source ../backup_scripts/backup.lib.sh

DEBUG=1


TESTALL=""
TESTALL=1

TESTCOUNT=0
PASSED=0
SKIPPED=0
mnt2_7="./mnt2.7"
mnt2_21="./mnt2.21"
s3bucket=kgp-test
sysinfo="/etc/opi/sysinfo.conf"
authkey="/var/opi/etc/syspriv.pem"
pyauth="/usr/lib/python3/dist-packages/pylibopi.py"
auth_file="auth.conf.test"

s3ql_quiet="--quiet"


function PASSFAIL {
	case $1 in
		$PASS)
			PASSED=$(( PASSED + 1 ))
			echo -e "   ${green}PASS${nc}"
		;;
		$SKIP)
			SKIPPED=$(( SKIPPED + 1 ))
			echo -e "   ${green}PASS${nc}"
		;;
		*)
			echo -e "   ${red}FAIL${nc}"
			;;
	esac
			
}

function STARTTEST {
	local type
	if [[ -z "$2" ]]; then
		type="TEST"
		TESTCOUNT=$(( TESTCOUNT + 1 ))
	fi
	echo -e "${yellow}   -----  $type: $1 ----- ${nc}"	
}


function umount_all {
	debug "Unmount all s3ql filesystems"
	mounted_fs=$(sed -n "s%\(^\w*://.*\)\s/.*%\1% p" /proc/mounts)
	for fs in $mounted_fs
	do
		sudo umount $fs
	done
	# remove all cached data
	rm -rf ~/.s3ql

	grep -q $device_mountpath /proc/mounts
	if [[ $? -eq 0 ]]; then
		debug "Unmount $device_mountpath"
		sudo umount $device_mountpath
	fi
	#check if any FS still exist
	grep -q "^[a-z0-9]*:\/\/" /proc/mounts
	status=$?
	if [[ $status -eq 0 ]]; then
		echo -e "${red} ERROR: FS still exists.${nc}"
	fi
}

function wipe_bucket {
	debug "Wiping S3 bucket: $1"
	#for version in ${versions[@]}
	#do
		local version="v2_21"
		debug "Wipe $version"
		echo "yes" | s3qladm $s3ql_quiet --authfile ${auth_file} clear s3://$1/$version > /dev/null
	#done
}


function get_def_path {
	# modifies the global "$path variable"
	local backend=$1

    if [[ $backend == "s3://" ]]; then
		path=$s3bucket
	fi

    if [[ $backend == *local* ]]; then
        # check if we have a usb-mem mounted somewhere
        path=$(get_localpath)
        if [[ -z "$path" ]]; then
            # no mem mounted, try to get one
            path=$(mount_localdevice)
            if [[ -z "$path" ]]; then
                # there is no suitable device mounted
                return
            fi
        fi
    fi
}

function wipe_targets {

	debug "Wiping all server targets"
	for backend in ${backends[@]}
	do

		debug "Setup urls for $backend"
		unset storage_urls
		declare -A storage_urls
		unset CA
	    declare -A CA

	    local path
	    get_def_path $backend

        if [[ $backend == "local://" && -z "$path" ]]; then
            # there is no suitable device mounted
            continue
        fi

        # setup storage_urls
        get_urls $path

		for version in ${versions[@]}
		do
			debug "VER1: $version Backend: $backend"
			wipe_fs $version
		done
        if [[ $backend == "local://" ]]; then
            sudo umount $path            
        fi

	done
}

function init_cfg {
	filename=$(basename "$1")
	if [[ -e $1 ]]; then
		debug "Backup $filename"
		backupfile="$filename.bak"
		i="0"
		while [[ -e "${backupfile}.${i}" ]]
		do
			i=$(( i + 1 ))
		done
		sudo cp $1 ./${backupfile}.${i}
		sudo cp $filename.test $1
		debug "Using ${backupfile}.${i}"
		# return ("echo") the value.
		echo ${backupfile}.${i}
	else
		debug "Could not find config file"
	fi
}

function restore_cfg {
	local src=$1
	local target=$2
	if [[ -e $src ]] && [[ ! -z "$target" ]]; then
		debug "Restore $1 to $2"
		sudo cp $1 $2
		sudo rm -f $1
	else
		debug "Missing parameters"
	fi
	set +x
}

function failandexit {
	echo -e "${yellow}Clean up environment${nc}"
	restore_cfg "$sysinfo_bak" "$sysinfo"
	restore_cfg "$authkey_bak" "$authkey"
	umount_all
	
	echo -e "${red}ERROR: $2${nc}"	
	exit $1
}
function alldone {

	echo -e "${yellow}Clean up environment${nc}"
	restore_cfg "$sysinfo_bak" "$sysinfo"
	restore_cfg "$authkey_bak" "$authkey"
	restore_cfg "$pyauth_bak" "$pyauth"
	umount_all

# ------  Output stats. ----------
	
	echo -e "${purple}Test done (Test count: $TESTCOUNT)${nc}"
	if [[ $PASSED -eq $TESTCOUNT ]]; then
		echo -e "${green}ALL PASS${nc}"
		echo ""
	else
		echo -e "${red}Test(s) failed${nc} ( Passed: ${green}$PASSED${nc} / Skipped ${yellow}$SKIPPED${nc} / Failed: ${red}"$(( TESTCOUNT - PASSED - SKIPPED ))"${nc})"
	fi

	exit $1
}

debug "Set up environment"

sysinfo_bak=$(init_cfg $sysinfo)
authkey_bak=$(init_cfg $authkey)
pyauth_bak=$(init_cfg $pyauth)
source $sysinfo
debug "Using unit id: $unit_id"

umount_all
wipe_targets



debug "Set target to 'local://'"
sudo echo "backend=local://" > ${target_file}
backend="local://"

# read unit id from file

# ------- TEST  valid empty backends ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Testing get_valid_backends - with none present"
	# expect an empty return value
	declare -A valid_backends
	# this will populate the above "valid_backends"
	get_valid_backends $backend

	if [[ ${#valid_backends[@]} -eq 0 ]]; then
		PASSFAIL $PASS
	else
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  valid populated backends ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Testing get_valid_backends - with backend present"
	sudo mkdir -p ${mnt2_21} 
	fsck.s3ql $s3ql_quiet --authfile ${auth_file} local://./fs2.21
	retval=$?
	if [[ $retval -ne 0 ]]; then
		debug "FSCK returned $retval"
		failandexit
	fi
	sudo mount.s3ql $s3ql_quiet --authfile ${auth_file} local://./fs2.21 ${mountpoints[v2_21]}

	# expect an non-empty 'valid backends'
	unset valid_backends
	declare -A valid_backends
	
	get_valid_backends $backend

	umount_all

	if [[ ${#valid_backends[@]} -eq 1 ]]; then
		PASSFAIL $PASS
	else
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  get local path ------------------------
if [[ ! -z $TESTALL ]]; then

	STARTTEST "local path no mount"
	# expect an empty local path
	localpath=$(get_localpath)
	if [[ -z "$localpath" ]]; then
		PASSFAIL $PASS
	else
		PASSFAIL $FAIL
	fi

fi
#  ----------------------------------------------------

# ------- TEST  get local path mounted device----------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "local path mounted device"

	testpath="/tmp/usb"
	dummypath=$(mount_localdevice $testpath)
	status=$?

	if [[ $status -ne 0 ]]; then
		debug "Failed to mount usb device."
		PASSFAIL $FAIL
	else
		# expect an populated local path
		localpath=$(get_localpath)
		sudo umount $testpath
		if [[ "$localpath" == "$testpath" ]]; then
			debug "Local path: $localpath"
			PASSFAIL $PASS
		else
			PASSFAIL $FAIL
		fi
	fi
fi
#  ----------------------------------------------------

# ------- TEST  mount USB memory ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Mount Valid USB"
	# expect the mount path of the USB memory
	mountpath=$(mount_localdevice)
	if [[ ! -z $mountpath ]]; then
		sudo umount $mountpath
	fi
	if [[ $mountpath != $device_mountpath ]]; then
		PASSFAIL $FAIL
	else
		PASSFAIL $PASS
	fi
fi
#  ----------------------------------------------------

# ------- TEST  mount USB memory ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Mount non-Valid USB"
	path_bak=$backupdevice
	backupdevice="/dev/tty"
	# expect empty path
	mountpath=$(mount_localdevice)
	backupdevice=$path_bak
	if [[ -z "$mountpath" ]]; then
		PASSFAIL $PASS
	else
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  build LOCAL storage URLs ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "build storage URLs for local target"
	# expect urls to with correct targets

	unset storage_urls
	declare -A storage_urls
	unset CA
    declare -A CA

    backend="local://"
    path="/phonypath"
    get_urls $path
    retval=$?
    if [[ $retval -eq $PASS ]]; then
	    for version in "${versions[@]}";
	    do
	    	debug "Version: '$version', URL: '${storage_urls[$version]}'"
	    	if [[ "${storage_urls[$version]}" == *$backend* ]] && [[ ${storage_urls[$version]} == *$path* ]];then
	    		debug "URL passed test criteria"
	    	else
	    		debug "Missing required info in storage url"
	    		retval=$(( retval || FAIL))
	    	fi
		done
		PASSFAIL $retval
	else
		debug "ReturnValue $retval"
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  build s3op storage URLs ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "build storage URLs for s3op target"
	# expect urls to with correct targets

	unset storage_urls
	declare -A storage_urls
	unset CA
    declare -A CA

    backend="s3op://"
    get_urls
    retval=$?
    if [[ $retval -eq $PASS ]]; then
	    for version in "${versions[@]}";
	    do
	    	debug "Version: '$version', URL: '${storage_urls[$version]}'"
	    	if     [[ ${storage_urls[$version]} == *$backend* ]] \
	    		&& [[ ${storage_urls[$version]} == *$unit_id* ]] \
	    		&& [[ ${storage_urls[$version]} == *${s3op_fsprefix[$version]}* ]] ;then
	    		debug "URL passed test criteria"
	    	else
	    		debug "Missing required info in storage url"
	    		retval=$(( retval || FAIL))
	    	fi
		done
		PASSFAIL $retval
	else
		debug "ReturnValue $retval"
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  build S3 storage URLs ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "build storage URLs for S3 target"
	# expect urls to with correct targets

	unset storage_urls
	declare -A storage_urls
	unset CA
    declare -A CA

    backend="s3://"
    get_urls $s3bucket
    retval=$?
    if [[ $retval -eq $PASS ]]; then
	    for version in "${versions[@]}";
	    do
	    	#debug "Version: '$version', URL: '${storage_urls[$version]}'"
	    	if     [[ ${storage_urls[$version]} == *$backend* ]] \
	    		&& [[ ${storage_urls[$version]} == *$s3bucket* ]] \
	    		&& [[ ${storage_urls[$version]} == *${s3_fsprefix[$version]}* ]] ;then
	    		debug "URL passed test criteria"
	    	else
	    		debug "Missing required info in storage url"
	    		retval=$(( retval || FAIL))
	    	fi
		done
		PASSFAIL $retval
	else
		debug "ReturnValue $retval"
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  build S3 storage URLs - no bucket  ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "build storage URLs for S3 target - missing 'bucket'"
	# expect error 90 "Missing bucket"

	unset storage_urls
	declare -A storage_urls
	unset CA
    declare -A CA

    backend="s3://"
    get_urls
    retval=$?
    if [[ $retval -eq 90 ]]; then
		PASSFAIL $PASS
	else
		debug "ReturnValue $retval"
		PASSFAIL $FAIL
	fi
fi
#  ----------------------------------------------------

# ------- TEST  remove symlinks ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Remove symlinks"
	# expect users data dir to still exits but no "backup" link
	debug "Setup test dirs and links"
	testdir="./test/$nextcloud_dir"
	sudo mkdir -p $testdir
	sudo mkdir -p $testdir/john/files
	sudo mkdir -p $testdir/jane/files
	sudo mkdir -p /tmp/phonydir
	sudo ln -s /tmp/phonydir $testdir/john/files/backup
	sudo ln -s /tmp/phonydir $testdir/jane/files/backup

	removelinks $testdir
    retval=$?


    if [[ $retval -eq 0 ]]; then
    	if [[ -e $testdir/john/files/backup ]] || [[ -e $testdir/jane/files/backup ]]; then
    		debug "Links still exist"
    		status=$FAIL
    	else
    		if [[ -e $testdir/john/files/ ]] && [[ -e $testdir/jane/files/ ]]; then
				status=$PASS
			else
				status=$FAIL
			fi
		fi
	else
		debug "ReturnValue $retval"
		status=$FAIL
	fi

    debug "Clean dirs"
    sudo rm -rf ./test
    PASSFAIL $status
fi
#  ----------------------------------------------------

# ------- TEST  remove non existing symlinks ------------
if [[ ! -z $TESTALL ]]; then
	STARTTEST "Remove none existing symlinks"
	# expect the test dir to be intact
	debug "Setup test dirs and links"
	testdir="./test/$nextcloud_dir"
	sudo mkdir -p $testdir
	sudo mkdir -p $testdir/john/files
	sudo mkdir -p $testdir/jane/files

	removelinks $testdir
    retval=$?

    if [[ $retval -eq 0 ]]; then
		if [[ -e $testdir/john/files/ ]] && [[ -e $testdir/jane/files/ ]]; then
			status=$PASS
		else
			status=$FAIL
		fi
	else
		debug "ReturnValue $retval"
		status=$FAIL
	fi
	
    debug "Clean dirs"
    sudo rm -rf ./test
    PASSFAIL $status
fi
#  ----------------------------------------------------

# ------- TEST  FSCK on non existant FS------------

if [[ ! -z $TESTALL ]]; then
	for backend in "${backends[@]}";do
	#backend="local://"
		for version in "${versions[@]}"
		do
			STARTTEST "FSCK for '$backend' with version '$version' on non existant FS"
			# expect '18' as return value
			status=$FAIL
			# need storage urls
			unset storage_urls
			declare -A storage_urls
			unset CA
		    declare -A CA
		    if [[ $backend == "s3://" ]]; then
		    	phonypath="phonybucket"
		    else
		    	phonypath="/phonypath"
		    fi
			get_urls "$phonypath"
			if [[ $? -eq $PASS ]]; then
				fsck $version
				retval=$?
				if [[ $retval -eq 16 || $retval -eq 18 ]]; then
					# Missing s3ql filesystem or invalid storage url (can happen on usb when the path is not there.)
					status=$PASS
				else
					debug "FSCK returned '$retval'"
				fi
			fi	
			PASSFAIL $status
		done
	done
		
fi
#  ----------------------------------------------------


# ------- TEST  FSCK on existing path but non existant FS------------

if [[ ! -z $TESTALL ]]; then
	backend="local://"
		for version in "${versions[@]}"
		do
			STARTTEST "FSCK for '$backend' with version '$version' on existing path and non existant FS"
			# expect '18' as return value
			status=$FAIL
			# need storage urls
			unset storage_urls
			declare -A storage_urls
			unset CA
		    declare -A CA
	    	phonypath="/tmp/phonypath"
	    	sudo mkdir -p $phonypath 
			get_urls "$phonypath"
			if [[ $? -eq $PASS ]]; then
				fsck $version
				retval=$?
				if [[ $retval -eq 16 || $retval -eq 18 ]]; then
					# Missing s3ql filesystem or invalid storage url (can happen on usb when the path is not there.)
					status=$PASS
				else
					debug "FSCK returned '$retval'"
				fi
			fi	
			sudo rm -rf $phonypath
			PASSFAIL $status
		done
fi
#  ----------------------------------------------------


# ------- TEST  Create FS ------------
if [[ ! -z $TESTALL ]]; then
	# expect a S3ql FS on storage urls
	for backend in "${backends[@]}"
	do

		for version in "${versions[@]}";do
			STARTTEST "Create $version FS on $backend"
			# need storage urls
			unset storage_urls
			declare -A storage_urls
			unset CA
		    declare -A CA
		    case $backend in
		    	"s3://")
			    	path=$s3bucket
			    	if [[ $version == "v2_7" ]]; then
			    		debug "Create FS on S3 not supported for 2.7 version"
	   					PASSFAIL $SKIP
	   					continue
	   				fi
	   				;;
	   			"local://")
			    	path=$(get_localpath)
		   	        if [[ -z "$path" ]]; then
		            	# no mem mounted (and should not....), try to get one
			            path=$(mount_localdevice)
			            if [[ -z "$path" ]]; then
			                # there is no suitable device mounted
			                debug "No Suitable Target"
			                PASSFAIL $FAIL
			                continue
			            fi
		        	fi
		        	;;
		        *)
					;;
			esac

			get_urls $path

			create_fs $version
			PASSFAIL $?
		done
	done
	umount_all
fi
#  ----------------------------------------------------

# ------- TEST  Mount existing FS ------------
if [[ ! -z $TESTALL ]]; then
	# expect a mounted S3ql FS mountpoint
	# This test will fail if there is no FS on the backend.
	for backend in "${backends[@]}";do
		umount_all
		for version in "${versions[@]}";do
			STARTTEST "Mount existing $version FS for $backend on ${mountpoints[$version]}"

			# need storage urls
			unset storage_urls
			declare -A storage_urls
			unset CA
		    declare -A CA
		    case $backend in
		    	"s3://")
			    	path=$s3bucket
			    	if [[ $version == "v2_7" ]]; then
			    		debug "Create FS on S3 not supported for 2.7 version"
	   					PASSFAIL $SKIP
	   					continue
	   				fi
	   				;;
	   			"local://")
			    	path=$(get_localpath)
		   	        if [[ -z "$path" ]]; then
		            	# no mem mounted (and should not....), try to get one
			            path=$(mount_localdevice)
			            if [[ -z "$path" ]]; then
			                # there is no suitable device mounted
			                debug "No Suitable Target"
			                PASSFAIL $FAIL
			                continue
			            fi
		        	fi
		        	;;
		        *)
					;;
			esac

			get_urls $path
			mount_fs $version ${mountpoints[$version]} 
			
			PASSFAIL $?
		done
	done

fi
#  ----------------------------------------------------



# restore configs and output stats.
alldone