#!/bin/bash
#set -x

DEBUG=0
DIR=$(dirname "${BASH_SOURCE[0]}")
cd $DIR
source /etc/opi/sysinfo.conf
source backup.conf
source backup.lib.sh

function exit_fail {
    # Exit codes for s3ql documented in http://www.rath.org/s3ql-docs/man/
    # Additional:
    #  70 : No valid backend specified
    #  71 : No suitable target
    #  75 : Missing filesystem during restore
    #  90 : Missing 'bucket' for s3 backend
    #  99 : Device locked (luksdevice not present in /proc/mounts)
    echo ""
    echo -e "${red}Error detected, exit code '$1'${nc}"
    if [ ! -z "$2" ]; then
        echo -e "${purple}Message: $2${nc}"
    fi
    echo "Codes defined by this script:"
    echo "   1 : General, unspecified error "
    echo "  70 : No valid backend specified "
    echo "  71 : No suitable target "
    echo "  75 : Missing filesystem during restore "
    echo "  80 : Possible FS too new"
    echo "  90 : Missing 'bucket' for s3 backend "
    echo "  99 : Unit locked"

    exit $1

}

function check_fail {
    retval=$1
    if [[ $retval -ne $PASS ]]; then
        exit_fail $retval $2
    fi
}

grep -q $luksdevice /proc/mounts
if [[ $? -ne 0 ]]; then
    exit_fail 99 "Unit locked"
fi

if [ -e $target_file ]; then
	source  $target_file
else   
    echo "No target file"
	exit_fail $NoSuitableTarget
fi


# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

# Initialize our own variables:
restore=0


# cmd-line overrides config file parameters.
while getopts "b:a:m:rd" opt; do
    case "$opt" in
    a)  auth_file=$OPTARG
        ;;
    b)  backend=$OPTARG
        ;;
    m)  mountpoint=$OPTARG
	    ;;
    r)  restore=1
	    ;;
    d)  DEBUG=1
        ;;
    ?)	exit 1
	   ;;
    esac
done



shift $((OPTIND-1))

[ "$1" = "--" ] && shift

backend_ok=$FAIL
for b in "${backends[@]}"; do
    if [[ $b == $backend ]]; then
        echo "'$backend' is a supported backend"
        backend_ok=$PASS
        break
    fi
done
if [[ $backend_ok -ne $PASS ]]; then
    echo "'$backup' is not a valid backend"
    exit_fail NoBackendSpecified
fi


# find out if there are any mounted backend
declare -A valid_backends

# get_valid_backends populates the global "valid_backends" array
get_valid_backends $backend

debug "Number of valid backends: ${#valid_backends[@]}"
if [[ ${#valid_backends[@]} -gt 0 ]]; then
    # Nothing more to do, use the valid backend(s)
    # Do not exit here since this script is sourced by the backup-scirpts
    # and and "exit" will terminate that script.
    echo "Using existing backends"
else

    echo "No currently valid backends."

    case $backend in
        "local://")
            # check if we have a usb-mem mounted somewhere
            path=$(get_localpath)
            if [[ -z "$path" ]]; then
                # no mem mounted, try to get one
                path=$(mount_localdevice)
                if [[ -z "$path" ]]; then
                    # there is no suitable device mounted
                    exit_fail $NoSuitableTarget "No Suitable Target"
                fi
            fi
            ;;
        "s3://")
            # setup path to be 'bucket' read from target.conf
            path=$bucket
            ;;
        *)
            ;;
    esac

    echo "Backend to use: $backend"
    declare -A storage_urls
    declare -A CA
    declare -A valid_fs

    # get the storage backend url(s)
    echo "Setup storage URLs"
    get_urls $path
    check_fail $? "Failed to get storage urls"

    # Create cache dir
    sudo mkdir -p $s3ql_cachedir
    check_fail $? "Failed to create cache dir"

    echo "Remove any existing old symlinks"
    removelinks $nextcloud_dir
    check_fail $? "Failed remove symlinks to NextCloud dirs"

    for version in "${versions[@]}"
    do
        echo -n "Running FSCK for version '$version' ..."
        fsck $version
        retval=$?
        echo "  DONE, result '$retval'"
        debug "Version: $version, Valid: $retval"
        valid_fs[$version]=$retval
    done

    for version in "${versions[@]}"
    do
        case ${valid_fs[$version]} in
            0)
                debug "Valid FS for version '$version'"
                ;;
            16|18)
                debug "No FS for version '$version' found."
                if [[ $version == $CURRENT_VERSION && $restore -ne 1 ]]; then
                    debug "Create FS with verson '$version'"
                    create_fs 
                    valid_fs[$version]=$?
                fi
                ;;
            17)
                exit_fail ${valid_fs[$version]} "Invalid passphrase"
                ;;

            $PossibleFSTooNew)
                exit_fail ${valid_fs[$version]} "Unexpected error, possible 2.21 FS with 2.7 backend."
                ;;
            *)
                debug "Unexpected error from FSCK"
                exit_fail ${valid_fs[$version]} "Unexpected error from FSCK"
        esac
    done


    if [[ ${#valid_fs[@]} -gt 0 ]]; then
        # Mount valid FS's
        for version in "${versions[@]}"
        do
            if [[ ${valid_fs[$version]} -eq 0 || ${valid_fs[$version]} -eq 128 ]]; then
                echo "Trying to mount FS with '$version'"
                if [[ ! -z "$mountpoint" ]]; then
                    # override mountpoint, mount the first valid FS found
                    # prio order is set by "versions" array
                    echo "Using mountpoint override '$mountpoint'"
                    mount_fs $version $mountpoint
                    status=$?
                    if [[ $status -eq 0 ]]; then
                        debug "Mounted $backend"
                        break
                    fi
                    check_fail $status "Failed to mount FS"
                else
                    mount_fs $version ${mountpoints[$version]}
                    status=$?
                    check_fail $status "Failed to mount FS"
                fi
                
            fi
        done
    else
        exit_fail $NoSuitableTarget "No valid targets for backup"
    fi


fi
# this script is 'sourced' from s3ql-backup and must not exit if nothing is wrong.






