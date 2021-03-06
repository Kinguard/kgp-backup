#!/bin/bash
#
# backup.lib.sh
#
# This is a pure function file to be included in other scripts.
# This "lib" requires that "backup.conf" has previously been sourced.

# IMPORTANT: Only use 'echo' to return strings from the functions, otherwise use
# 'debug' that is directed to stderr.
# Main program output should be enough to put in the backup log.

# There should never be different types of backends mounted so always to comparisons
# against CURRENT_VERSION if only one can be tested

#CURRENT_VERSION=$(s3qladm --version | awk '{print $(NF)}')
CURRENT_VERSION="v2_21"


# create useful arrays
# these arrays are used as global variables and accessed from 
# files including this "lib"

backends=( "local://" "s3op://" "s3://")
versions=( "v2_21" ) # order here is important, it is prio order when only one can be used


declare -A mountpoints
BackupRootPath=$(kgp-sysinfo -s -p | grep "BackupRootPath" | awk '{print $2}')
mountpoints=([v2_7]="${BackupRootPath}${mount_v2_7}" [v2_21]="${BackupRootPath}${mount_v2_21}")

declare -A local_fsprefix
local_fsprefix=([v2_7]="${local_fsprefix_v2_7}" [v2_21]="${local_fsprefix_v2_21}")

declare -A s3op_fsprefix
s3op_fsprefix=([v2_7]="${s3op_fsprefix_v2_7}" [v2_21]="${s3op_fsprefix_v2_21}")

declare -A s3_fsprefix
s3_fsprefix=([v2_7]="${s3_fsprefix_v2_7}" [v2_21]="${s3_fsprefix_v2_21}")

declare -A PYPATH
PYPATH=([v2_7]="${PYPATH_v2_7}" [v2_21]="")

declare -A s3qlpath
s3qlpath=([v2_7]="${s3qlpath_v2_7}" [v2_21]="${s3qlpath_v2_21}")

###  define ansi colors
red="\033[0;31m"
green="\033[0;32m"
purple="\033[1;35m"
yellow="\033[1;33m"
nc="\033[0m"


function debug {
    # redirect debug log to stderr
    if [[ $DEBUG -ne 0 ]]; then
	logger -s -p daemon.notice "kgp-backup: $1"
    fi
}

function s3ql_running {
    local status
    debug "Checking if s3ql is running"
    if [[ ! -z "$1" ]]; then
        path=${s3qlpath[$1]}
    fi

    ps ax | grep "${path}mount.s3ql" | grep -qv 'grep'
    status=$?

    debug "S3QL status: '$status'"
    return $status
}

function s3ql_kill {
    local loopcount=0
    local status

    if [[ ! -z "$1" ]]; then
        path=${s3qlpath[$1]}
    fi

    while [[ "$loopcount" -le "$s3ql_timeout" ]]
    do
        loopcount=$((loopcount+1))
        ps ax | grep "${path}mount.s3ql" | grep -qv 'grep'
        status=$?
        if [[ $status -eq 1 ]]; then
            break
        else
            debug "Waiting for s3ql to terminate..."
            sleep 1
        fi
    done

    if [[ $status -eq 0 ]]; then
        debug "Killing old processes"

        if [[ ! -z "$1" ]]; then
            path=${s3qlpath[$1]}
        fi
        sudo killall -9 ${path}mount.s3ql
    else
        debug "s3ql already terminated"
    fi
}

function check_valid_device {
    local backend=$1
    local mntpoint=$2
    debug "Check validity of the backend"
    if [[ $backend == *"local://"* ]]; then
        # does the "s3ql_passphrase" exist on the supplied path?
        # do not include possible trailing "/" of the mountpoint
        FSlocation=$(sed -n "s%local://\([^[:space:]]*\)/\? ${mntpoint}.*%\1% p" /proc/mounts)
        if [[ -e "$FSlocation/s3ql_passphrase" ]]; then
            status=$PASS
        else
            status=$FAIL
        fi
    else
        debug "No device needed for non-local backends"
        status=$PASS
    fi
    debug "Valid device: $status"
    return $status
}

function check_expire_state {
    # ok for file to be missing
    local statefile=".expire_backups.dat"
    local statestatus
    if [[ -e $statefile ]]; then
        # temporary allow failure
        # for some reason trailing characters are added to the json object.
        # json_pp can read it but 'expire backups can't
        # so if json_pp can read it, do so and write it back again.
        set +e
        content=$(cat $statefile | json_pp -json_opt allow_singlequote > $statefile)
        statestatus=$?
        set -e
        if [[ $statestatus -ne 0 ]]; then
            debug "State file content is not a valid json string, deleting"
            rm -f $statefile
        else
            debug "Valid state file content"
        fi
    fi
    return 0
}

function get_valid_backends {
    # find out if there are any mounted backend
    # use global "valid_backends object" (or implicity declare it...)

    local backend
    local s3ql_status
    local devicestatus
    local mounts
    declare -A current_backends

    backend=$1

    # Find all mounted backends
    mounts=$(grep [a-z0-9]*:\/\/ /proc/mounts | awk '{print $1 ";" $2}')
    for mount in $mounts
    do
        IFS=';' read -r key val <<<"$mount"
        current_backends[$key]=$val
    done

    if [ "${#current_backends[@]}" -ne "0" ]; then
        for mount in "${!current_backends[@]}";
        do
            local loopcount=0
            debug "BACKEND: $mount on '${current_backends[$mount]}'"
            check_valid_device $mount ${current_backends[$mount]}
            devicestatus=$?
            s3ql_running
            s3ql_status=$?

            debug "Test if the backend is valid"
            if [[ "$mount" == *"$backend"* && $devicestatus -eq 0 && $s3ql_status -eq 0  ]]; then
                valid_backends[$mount]=${current_backends[$mount]}
            else
                debug "Unmount device '$mount' from '${current_backends[$mount]}'"
                while [[ "$loopcount" -le "$s3ql_timeout" ]]
                do
                    loopcount=$((loopcount+1))
                    sudo fusermount -u ${current_backends[$mount]}
                    if [[ $? -eq 0 ]]; then
                        break
                    else
                        debug "Trying to run 'fusermount -u' again in 1 sec..."
                        sleep 1
                    fi
                done

            fi
        done
        for mount in "${!valid_backends[@]}"
        do
            debug "   --lib--  backend: $mount '${valid_backends[$mount]}'"
        done

    else
        debug "No backends mounted"
        #Kill all s3ql process if there is no backend mounted.
        s3ql_running
        s3ql_status=$?
        if [[ $s3ql_status -eq 0 ]]; then
            s3ql_kill
        fi
    fi
}

function get_localpath {

    local local_device
    local localpath
    local fs_mounted
    local realpath

    debug "Trying to find a suitable device on 'default' location ($device_mountpath)"
    # Need to have the trailing space included here in order not to get false positives
    local_device=$(grep "$device_mountpath " /proc/mounts | awk '{print $1}')
    if [ ! -z "$local_device" ]; then
        if [ -b $local_device ] ; then
            # the mountpoint exists and so does the device, lets use it.
            debug "Usable device found ('$local_device') on default location"
            localpath=$device_mountpath
        else
            debug "The mounted device does not exist, unmount"
            for version in "${versions[@]}"
            do
                # unmount possible s3ql fs
                grep -qs ${mountpoints[$version]} /proc/mounts
                fs_mounted=$?

                if [ $fs_mounted -eq 0 ]; then
                    debug "Try to unmount S3QL FS from: ${mountpoints[$version]}"
                    sudo umount ${mountpoints[$version]}
                fi
            done
            debug "Unmounting ${mountpoints[$version]}"
            sudo umount $device_mountpath
        fi
    else
        debug "Nothing on 'default' location"
    fi

    if [[ -z "$localpath" ]]; then
        # No suitable device found, check if there is a usb mem mounted anywhere else
        for device in ${backupdevice}; do
            debug "Checking if device '$device' is mounted"
            realpath=$(realpath $device)
            if [ ! -z "$realpath" ]
            then
                grep -qs "^$realpath" /proc/mounts
                if [[ $? -eq 0 ]]; then
                    debug "Device $device is mounted, find out where"
                    localpath=$(grep $realpath /proc/mounts | awk '{print $2}')
                    break
                 fi
            else
                 debug "Path to device not found"
            fi
        done
    fi
    if [[ -z "$localpath" ]]; then
        debug "No local device is mounted and suitable for use"
    else
        debug "Usable local device is found on $localpath"
        echo $localpath
    fi
}

function mount_localdevice {
    # create mountpoint for disk
    local mountpath
    if [[ ! -z "$1" ]];then
        #override mountpath
        mountpath=$1
        debug "Override default mnt path, using '$mountpath'"
    else 
        mountpath=$device_mountpath  
    fi
    sudo mkdir -p $mountpath
    shopt -s nullglob

    for device in ${backupdevice}; do
        debug "Device: $device, try to mount it"
        if [ -b "$device" ] ; then
            sudo mount $device $mountpath
            if [[ $? -eq 0 ]]; then
                debug "Device $device mounted"
                debug "Local path: $mountpath"
                echo $mountpath
                break
            else
                debug "Failed to mount '$device'"
            fi
         else
            debug "Failed to mount '$device'"
        fi
    done
}

function get_urls {

    # build a storage url based on the current "backend" (sourced from backup.conf in prod env.)
    # for local target arg is the path to the mounted device (/mnt/usb)
    # either the 'localpath' for "local-target" or 'bucket' for s3 is passed in $1
    local localpath=$1
    local bucket=$1
    local version

    for version in "${versions[@]}"
    do
        debug "Setup storage urls for version: $version"
        if [[ $backend == *local* ]]; then
            storage_urls[$version]="${backend}${localpath}${local_fsprefix[$version]}"
        elif [[ $backend == *s3op://* ]]; then
            storage_urls[$version]="${backend}$storage_server/${unit_id}${s3op_fsprefix[$version]}"
            CA[$version]=" "
        elif [[ $backend == *s3://* ]]; then
            if [ -z "$bucket" ]; then
                debug "Missing Bucket"
                return $MissingBucket
            else        
                storage_urls[$version]="${backend}${bucket}${s3_fsprefix[$version]}"
            fi
        else
            return $NoBackendSpecified
        fi
        debug "Ver: '$version' URL: ${storage_urls[$version]}"
    done

}

function removelinks {
    linkdir=$1
    local pass=$PASS
    # remove any old symlinks
    debug "Removing symlinks for $linkdir"
    if [[ -d "$linkdir" ]]; then
        for dir in $linkdir*/ ; do
            if [[ -L "${dir}/files/backup" && -d "${dir}/files/backup" ]]; then
                debug "Removing symlink to backupdir '$dir/files/backup'."
                sudo rm -rf "${dir}/files/backup"
                pass=$(( pass || $?))
            fi
        done
    else
        debug "'linkdir' does not exist"
    fi
    return $pass
}

function wipe_fs {
    # requrires storage_urls to be properly setutp
    # $1 version
    if [[ -z "$1" ]]; then
        debug "Missing version"
        return 1
    else
        local version=$1
    fi

    debug "Wipe ${storage_urls[$version]}"
    #echo             "${PYPATH[$version]}${s3qlpath[$version]}s3qladm ${CA[$version]} --authfile ${auth_file} clear ${storage_urls[$version]}"
    echo "yes" | sudo ${PYPATH[$version]}${s3qlpath[$version]}s3qladm ${CA[$version]} --authfile ${auth_file} clear ${storage_urls[$version]} &> /dev/null
}

function fsck {
    # global storage_urls and CA is required
    # "version" is passed as first arg
    
    local fsck_msg
    local fsck_result

    if [[ -z "$1" ]]; then
        debug "Missing 'version' in call to FSCK"
        return 1
    fi
    local version=$1

    # 2.7 does not handle missing paths very well (returns '1'), check that first.
    # Nothing good to check for in the output either.
    if [[ "$backend" == "local://" ]] && [[ "$version" == "v2_7" ]]; then
        local storagepath=${storage_urls[$version]}
        local path=${storagepath:8}
        if [[ ! -e $path ]]; then
             return 16
        fi
    fi
    debug "Running fsck for version '$version'"
    #local cmd="sudo ${PYPATH[$version]}${s3qlpath[$version]}fsck.s3ql ${CA[$version]} --quiet --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  ${storage_urls[$version]}"
    #debug "    sudo ${PYPATH[$version]}${s3qlpath[$version]}fsck.s3ql $s3ql_quiet ${CA[$version]} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  ${storage_urls[$version]}"
    fsck_msg=$(sudo ${PYPATH[$version]}${s3qlpath[$version]}fsck.s3ql $s3ql_quiet ${CA[$version]} --cachedir ${s3ql_cachedir} --log $log_file --authfile ${auth_file}  ${storage_urls[$version]} 2>&1)
    fsck_result=$?
    #debug "MSG $fsck_msg"
    if [[ $fsck_result -eq 1 && "$version" == "v2_7" ]]; then
        if [[ "$fsck_msg" == *"No S3QL file system found"* ]]; then
            # 2.7 returns 1 for a missing filesystem
            fsck_result=18
        elif [[ "$fsck_msg" == *"Invalid credentials"* ]]; then
            # 2.7 returns 1 with invalid credentials
            fsck_result=14
        elif [[ "$fsck_msg" == *"NoSuchBucket"* ]]; then
            # 2.7 returns 1 for a missing bucket
            fsck_result=16
        elif [[ "$fsck_msg" == *"Wrong file system passphrase"* ]]; then
            # 2.7 returns 1 for a missing bucket
            fsck_result=17
        elif [[ "$fsck_msg" == *"_pickle.UnpicklingError: unpickling stack underflow"* ]]; then
            # 2.7 returns if it is given a new FS
            fsck_result=$PossibleFSTooNew
        fi

    fi

    return $fsck_result
}

function create_fs {
    # $1 as version (defaults to CURRENT_VERSION)
    local version
    if [[ -z $1 ]]; then
        version=$CURRENT_VERSION
    else
        version=$1
    fi
    debug "Create FS on ${storage_urls[$version]}"

    if [[ $backend == "local://" ]]; then
        # Try to create the dir for the FS
        local storagepath=${storage_urls[$version]}
        local path=${storagepath:8}
        sudo mkdir -p $path
        retval=$?
        if [[ $retval -ne 0 ]]; then
            debug "Failed to crete directory for FS on target device"
            return $retval
        fi
    fi
    #debug "sudo ${PYPATH[$version]}${s3qlpath[$version]}mkfs.s3ql  ${CA[$version]} --cachedir ${s3ql_cachedir} --authfile ${auth_file} ${storage_urls[$version]}"
    sudo ${PYPATH[$version]}${s3qlpath[$version]}mkfs.s3ql $s3ql_quiet ${CA[$version]} --cachedir ${s3ql_cachedir} --authfile ${auth_file} ${storage_urls[$version]} &> /dev/null
    local retval=$?
    return $retval
}

function upgrade_fs {
    # using global $storage_urls
    # $1 as version (defaults to CURRENT_VERSION)

    debug "Attempting to upgrade filesystem"

    local version
    if [[ -z $1 ]]; then
        version=$CURRENT_VERSION
    else
        version=$1
    fi

    # Upgrade fails with old cache data present
    debug "Cleaning up cache: ${s3ql_cachedir}/*"
    rm -rf ${s3ql_cachedir}/*
    debug "Result $?"

    #debug "sudo ${PYPATH[$version]}${s3qlpath[$version]}s3qladm --debug --log $log_file --cachedir ${s3ql_cachedir} --authfile ${auth_file} upgrade  ${storage_urls[$version]}"
    sudo ${PYPATH[$version]}${s3qlpath[$version]}s3qladm --debug --log $log_file --cachedir ${s3ql_cachedir} --authfile ${auth_file} upgrade  ${storage_urls[$version]} &> /dev/null

    local retval=$?
    debug "Retval: $retval"
    return $retval
}

function mount_fs {
    # using global $storage_urls
    # $1 as version (defaults to CURRENT_VERSION)
    # $2 as mountpath
    local version
    local mountpath
    if [[ -z $1 ]]; then
        version=$CURRENT_VERSION
    else
        version=$1
    fi

    if [[ -z $2 ]]; then
        debug "Missing mount path"
        return 1
    else
        mountpath=$2
    fi

    sudo mkdir -p $mountpath
    retval=$?
    if [[ $retval -ne 0 ]]; then
        debug "Failed to crete mountpoint"
        return $retval
    fi

    if isOpi=$(kgp-sysinfo -i Opi); then
        # OPI does not have enough memory
        s3ql_cachesize=$s3ql_cachesize_OPI
    fi

    #debug "sudo ${PYPATH[$version]}${s3qlpath[$version]}mount.s3ql --allow-other --cachedir ${s3ql_cachedir} --cachesize ${s3ql_cachesize} $s3ql_quiet ${CA[$version]} --authfile ${auth_file} ${storage_urls[$version]} $mountpath"
    sudo ${PYPATH[$version]}${s3qlpath[$version]}mount.s3ql --log $log_file --allow-other --cachedir ${s3ql_cachedir} --cachesize ${s3ql_cachesize} $s3ql_quiet ${CA[$version]} --authfile ${auth_file} ${storage_urls[$version]} $mountpath
    return $?

}
