<?php
set_time_limit(0);

require_once "lib/base.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

OCP\App::checkAppEnabled('calendar');

echo "Calendar enabled\n";
$inpath = ".";

if( count( $argv ) >= 2 )
{
	$inpath = $argv[1];
}

echo "Using inpath: $inpath\n";

$dirs = glob($inpath ."/*", GLOB_ONLYDIR | GLOB_NOSORT);

foreach( $dirs as $dir )
{
	$user = pathinfo( $dir, PATHINFO_BASENAME );
	
	OC_User::setUserId($user);

	$calendars = glob( $dir . "/calendars/*", GLOB_NOSORT );

	foreach( $calendars as $calendar )
	{
		if( ! is_file( $calendar ) )
		{
			continue;
		}

		$name = pathinfo( $calendar, PATHINFO_BASENAME);
		$calname = "Imported_" . pathinfo($name,PATHINFO_FILENAME);

		$id = OC_Calendar_Calendar::addCalendar($user, $name);

		$ical = file_get_contents( $calendar );

		$importer = new OC_Calendar_Import( $ical );

		$importer->setCalendarID($id);
		$importer->setUserID($user);
		if( ! $importer->import() )
		{
			OC_Calendar_Calendar::deleteCalendar($id);
		}

	}
}


