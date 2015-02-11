#! /bin/bash
#set -e

echo "Start restore operation"

if [ $# -lt 1 ]
then 
	echo "Missing argument"
	exit 1
fi 

RESTOREPATH=$1
MYSQLCONF=/usr/share/opi-backup/my.cnf

echo "Restore from $RESTOREPATH"

function mp()
{ 
  #echo "Check if mysql is running"
  mysqladmin --defaults-file=$MYSQLCONF -s ping
}

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

echo "Restore database from backup"
mysql --defaults-file=$MYSQLCONF < $RESTOREPATH/system/opi.sql

echo "Shut down temporary mysql instance"
mysqladmin --defaults-file=$MYSQLCONF shutdown

echo "Clean install target"
# Make sure we have no dangling certs
rm /mnt/opi/etc/*.pem

# Copy data from backup

echo "Restore system data"
rsync -a --info=progress2 $RESTOREPATH/system/opi /mnt/

echo "Restore user data"
rsync -a --info=progress2 $RESTOREPATH/userdata/* /mnt/opi/owncloud/data/

echo "Fixup environment"
# Make sure OC gets its precious stamp file
touch /mnt/opi/owncloud/data/.ocdata

# setup correct permissions
chmod 0755 /mnt/opi

chown -R fetchmail:nogroup /mnt/opi/fetchmail/
chmod 755 /mnt/opi/etc/
chmod 0755 /mnt/opi/mail/
chown -R postfix:postfix /mnt/opi/mail/*
chown -R 5000:5000 /mnt/opi/mail/data
chmod 0770 /mnt/opi/mail/data/

chmod 0755 /mnt/opi/owncloud/
chown -R  www-data:www-data /mnt/opi/owncloud/data/*
chmod -R g+w /mnt/opi/owncloud/data/

chmod 0755 /mnt/opi/roundcube/
chown -R www-data:www-data /mnt/opi/roundcube/*

chown -R secop:secop /mnt/opi/secop

echo "Done with restore for $RESTOREPATH"
