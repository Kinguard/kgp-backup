#! /bin/bash

OUTFILE="/etc/cron.d/opi-backup"
M="$((RANDOM%60))"
H="$((RANDOM%8))"

if [ -e $OUTFILE ]
then
	echo "Crontab already exists, skipping crontab setup"
	exit 0
fi

echo "Setting up crontab entry for opi-backup"

OUT=$(cat << EOF
# crontab entry for opi-backup
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BSCRIPT="/usr/share/opi-backup/opi_backup.sh"

$M $H * * *	root test -x \$BSCRIPT && nohup \$BSCRIPT -p &
EOF
)

echo "$OUT" > $OUTFILE
