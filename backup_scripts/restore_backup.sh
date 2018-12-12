#! /bin/bash
#set -e

echo "Start restore operation"
src=$(realpath "${BASH_SOURCE[0]}")
DIR=$(dirname $src)
cd $DIR

source backup.conf

if [ $# -lt 1 ]
then 
	echo "Missing argument"
	exit 1
fi 

RESTOREPATH=$1
BASEPATH=$2
MYSQLCONF=/usr/share/opi-backup/my.cnf

state=0
max_states=7

echo "Restore from $RESTOREPATH"
echo "Using basepath: '$BASEPATH'"

function state_update {
	if [[ -z "$state" ]]; then
		state=1
	else
		state=$((state + 1))
	fi
	echo $1
	echo '{"state":"'$state'", "desc":"'$1'","max_states":"'$max_states'"}' > $statefile
}

function mp()
{ 
  #echo "Check if mysql is running"
  mysqladmin --defaults-file=$MYSQLCONF -s ping
}

function startsql()
{

	echo "Start temporary mysql"

	# Start mysql temporarily for restore
	/usr/bin/mysqld_safe --defaults-file=$MYSQLCONF > /dev/null 2>&1 &

	echo "Wait for mysql to start up"
	t=15
	c=1
	while [ $c -lt $t ] && ! mp
	do
		echo "Waiting ($c)"
		(( c++ ))
		sleep 1
	done

	if [ $c -eq $t ]
	then
		echo "Failed to start mysql"
		exit 1
	fi
}

function restoredb()
{
	echo "Restore database from backup"
	mysql --defaults-file=$MYSQLCONF < $RESTOREPATH/system/opi.sql
}

function stopsql()
{
	echo "Shut down temporary mysql instance"
	mysqladmin --defaults-file=$MYSQLCONF shutdown
}

state_update "Clean install target"

# Make sure we have no dangling certs
rm -f $BASEPATH/mnt/opi/etc/*.pem

# Copy data from backup

echo -n "Reading unit-id: "
unit_id=$(kgp-sysinfo -p -c hostinfo -k unitid)
echo "$unit_id"

state_update "Restore system data"
# owncloud data has incorreclty been included in older backups, no need to restore that here.
mkdir -p $BASEPATH/mnt/
rsync -ahv --info=progress2 --exclude "owncloud/data" $RESTOREPATH/system/opi $BASEPATH/mnt/  > ${progressfile}

state_update "Restore system configs"
mkdir -p $BASEPATH/etc/
rsync -ahv --info=progress2 $RESTOREPATH/system/etc/opi $BASEPATH/etc/  > ${progressfile}

# Restore unit-id as this can be different if restored on a new system with a new unit-id
kgp-sysinfo -w "$unit_id" -c "hostinfo" -k "unitid"

state_update "Restore user data"
mkdir -p $BASEPATH/mnt/opi/nextcloud/data/
rsync -ahv --info=progress2 $RESTOREPATH/userdata/* $BASEPATH/mnt/opi/nextcloud/data/  > ${progressfile}

state_update "Setup environment and file permissions"
# Make sure OC gets its precious stamp file
touch $BASEPATH/mnt/opi/nextcloud/data/.ocdata

# setup correct permissions
chmod 0755 $BASEPATH/mnt/opi

chown -R fetchmail:nogroup $BASEPATH/mnt/opi/fetchmail/
chmod 755 $BASEPATH/mnt/opi/etc/
chmod 0755 $BASEPATH/mnt/opi/mail/
chown -R postfix:postfix $BASEPATH/mnt/opi/mail/*
chown -R 5000:5000 $BASEPATH/mnt/opi/mail/data
chmod 0770 $BASEPATH/mnt/opi/mail/data/

chmod 0755 $BASEPATH/mnt/opi/nextcloud/
chown -R  www-data:www-data $BASEPATH/mnt/opi/nextcloud/data
chmod -R og+w $BASEPATH/mnt/opi/nextcloud/data

chmod 0755 $BASEPATH/mnt/opi/roundcube/
chown -R www-data:www-data $BASEPATH/mnt/opi/roundcube/*

chown -R secop:secop $BASEPATH/mnt/opi/secop

startsql

# Import contacts and calendars
state_update "Import contacts and calendars"

php /usr/share/nextcloud/calendars_import.php "$RESTOREPATH/userdata"
php /usr/share/nextcloud/contacts_import.php "$RESTOREPATH/userdata"

stopsql

echo "Used $states states."
state_update "Done with restore for $RESTOREPATH"
