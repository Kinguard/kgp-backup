<?php
set_time_limit(0);

require_once "lib/base.php";

OCP\App::checkAppEnabled('calendar');

echo "Calendar enabled\n";
$outpath = ".";

if( count( $argv ) > 2 )
{
	$outpath = $argv[1];
}

$users = OCP\User::getUsers();

foreach( $users as $user )
{
	echo "User: $user\n";
	// Ignore errors for now
	$dir = $outpath . "/" . $user . "/calendars";
	mkdir( $dir , 0700, true);
	if( ! is_dir( $dir ) )
	{
		echo "Failed to create directory: $dir\n";
		continue;
	}

	$calendars = OC_Calendar_Calendar::allCalendars($user);
	foreach( $calendars as $calendar)
	{
		$filename = $dir . '/' . str_replace(' ', '-', $calendar['displayname']) . '.ics';
		echo "File: $filename\n";
		$caldata = OC_Calendar_Export::export($calendar["id"], OC_Calendar_Export::CALENDAR);
		file_put_contents( $filename, $caldata); 
	}
}

