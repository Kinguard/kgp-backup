#! /bin/bash
#set -e

LOGNAME="KGP Restore"
LOGLEVEL=8

source /usr/share/kgp-bashlibrary/scripts/kgp-logging.sh

log_notice "Start restore operation"

src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

# Set default values

# Prefix for destination path, seems unused atm.
BASEPATH=""

# Path to where _user_ storage data should be written.
# i.e. not system configuration as hostname etc
DESTPATH=/mnt

# Path on device without separate storage partition
#DESTPATH=/var

MYSQLCONF=/usr/share/opi-backup/my.cnf

state=0
max_states=7

exit_fail()
{
	echo $@
	log_err "$@"
	exit 1
}



usage ()
{
	cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] -v [-i path] [-p path] sourcepath

Restore a mounted backup from sourcepath to this system.

Available options:

-h	Print this help and exit
-v	Print script debug info
-i	Do restore into this path
	usable when testing.
-p	Prefix path where user data is stored
	This is used since user data can be located
	at different places depending on type

EOF
}

# Parse cmdline
OPTIND=1
while getopts  ":hvi:p:" opt
do
	case "$opt" in
	h)
		usage
		;;
	i)
		BASEPATH=$OPTARG;
		;;
	p)
		DESTPATH=$OPTARG;
		;;
	v)
		LOGLEVEL=8
		;;
	:)
		exit_fail "Error -${OPTARG} requires an argument."
		;;
	?)
		usage
		exit 0
		;;
	esac
done

shift $((OPTIND-1))


if [ $# -lt 1 ]
then 
	log_err "Missing argument"
	exit 1
fi 

# Where should we read restore data from?
RESTOREPATH=$1

log_debug "Restore from  : ${RESTOREPATH}"
log_debug "Using basepath: ${BASEPATH}"
log_debug "Using prefix  : ${DESTPATH}"

function state_update {
	if [[ -z "$state" ]]; then
		state=1
	else
		state=$((state + 1))
	fi
	log_debug "State update: $1"
	echo '{"state":"'$state'", "desc":"'$1'","max_states":"'$max_states'"}' > $statefile
}

function mp()
{ 
  log_debug "Check if mysql is running"
  mysqladmin --defaults-file=$MYSQLCONF -s ping
}

rm -f /tmp/mysql-started

function startsql()
{

	if mp
	then
		log_debug "DB already running, skip start"
		return
	fi


	log_notice "Start temporary mysql"

	# Start mysql temporarily for restore
	/usr/bin/mysqld_safe --defaults-file=$MYSQLCONF > /dev/null 2>&1 &

	log_debug "Wait for mysql to start up"
	t=15
	c=1
	while [ $c -lt $t ] && ! mp
	do
		log_debug "Waiting ($c)"
		(( c++ ))
		sleep 1
	done

	if [ $c -eq $t ]
	then
		log_err "Failed to start mysql"
		exit 1
	fi

	touch /tmp/mysql-started
}

function restoredb()
{
	echo "Restore database from backup"
	mysql --defaults-file=$MYSQLCONF < $RESTOREPATH/system/opi.sql
}

function stopsql()
{

	if [ ! -e /tmp/mysql-started ]
	then
		log_debug "Temporary DB not started by us, no need to stop it"
		return
	fi

	rm -f /tmp/mysql-started

	if ! mp
	then
		log_notice "Temporary DB not running? Don't terminate"
		return
	fi

	log_notice "Shut down temporary mysql instance"
	mysqladmin --defaults-file=$MYSQLCONF shutdown
}

state_update "Clean install target"

# Make sure we have no dangling certs
# ?? this should be original /var/opi/etc where no certs currently is stored, disable for now
# rm -f ${BASEPATH}${DESTPATH}/opi/etc/*.pem

# Copy data from backup

log_debug "Reading unit-id"
unit_id=$(kgp-sysinfo -p -c hostinfo -k unitid)
log_debug "ID: $unit_id"

state_update "Restore system data"
# owncloud data has incorreclty been included in older backups, no need to restore that here.
# Restore /var/opi from $RESTOREPATH/system/opi
mkdir -p ${BASEPATH}${DESTPATH}/
rsync -ahv --info=progress2 --exclude "owncloud/data" $RESTOREPATH/system/opi ${BASEPATH}${DESTPATH}/  > ${progressfile}

state_update "Restore system configs"
# Restore /etc/opi
mkdir -p ${BASEPATH}/etc/
rsync -ahv --info=progress2 $RESTOREPATH/system/etc/opi ${BASEPATH}/etc/  > ${progressfile}

# Not sure old backup contains /etc/kinguard
# Restoring /etc/kinguard if present
if [ -d $RESTOREPATH/system/etc/kinguard ]
then
	rsync -ahv --info=progress2 $RESTOREPATH/system/etc/kinguard ${BASEPATH}/etc/  > ${progressfile}
fi

# Restore unit-id as this can be different if restored on a new system with a new unit-id
kgp-sysinfo -w "$unit_id" -c "hostinfo" -k "unitid"

state_update "Restore user data"
# Restore nextcloud user data /var/opi/nextcloud/data
mkdir -p ${BASEPATH}${DESTPATH}/opi/nextcloud/data/
rsync -ahv --info=progress2 --exclude "files/sysbackup" $RESTOREPATH/userdata/* ${BASEPATH}${DESTPATH}/opi/nextcloud/data/  > ${progressfile}

state_update "Setup environment and file permissions"
# Make sure OC gets its precious stamp file
touch ${BASEPATH}${DESTPATH}/opi/nextcloud/data/.ocdata

# setup correct permissions
chmod 0755 ${BASEPATH}/etc/opi
chmod 0755 ${BASEPATH}${DESTPATH}/opi

chown -R fetchmail:nogroup ${BASEPATH}${DESTPATH}/opi/fetchmail/
chmod 755 ${BASEPATH}${DESTPATH}/opi/etc/
chmod 0755 ${BASEPATH}${DESTPATH}/opi/mail/
chown -R postfix:postfix ${BASEPATH}${DESTPATH}/opi/mail/*
chown -R 5000:5000 ${BASEPATH}${DESTPATH}/opi/mail/data
chmod 0770 ${BASEPATH}${DESTPATH}/opi/mail/data/

chmod 0755 ${BASEPATH}${DESTPATH}/opi/nextcloud/
chown -R  www-data:www-data ${BASEPATH}${DESTPATH}/opi/nextcloud/data
chmod -R og+w ${BASEPATH}${DESTPATH}/opi/nextcloud/data

chmod 0755 ${BASEPATH}${DESTPATH}/opi/roundcube/
chown -R www-data:www-data ${BASEPATH}${DESTPATH}/opi/roundcube/*

chown -R secop:secop ${BASEPATH}${DESTPATH}/opi/secop

startsql

# Import contacts and calendars
state_update "Import contacts and calendars"

php /usr/share/nextcloud/calendars_import.php "$RESTOREPATH/userdata"
php /usr/share/nextcloud/contacts_import.php "$RESTOREPATH/userdata"

stopsql

log_debug "Used $states states."
state_update "Done with restore for $RESTOREPATH"
