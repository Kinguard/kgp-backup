<?php
use OCA\DAV\AppInfo\Application;
use OCA\DAV\CalDAV\CalDavBackend;
set_time_limit(0);

require_once "lib/base.php";
require_once "/usr/share/php/PhpSecop/Secop.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

$app = new Application();
$cont = $app->getContainer();
$app_mgr = $cont->get(AppManager::class);

if( ! $app_mgr->isInstalled('calendar') )
{
	print "Calendar not installed!";
	exit(0);
}

$outpath = ".";
if( count( $argv ) >= 2 )
{
	$outpath = $argv[1];
}

try
{

	// Get users directly out of secop
	$s = new Secop();
	$s->sockauth();

	list($status, $rep) = $s->getusers();
	if ( $status )
	{
		foreach( $rep["users"] as $user )
		{
			$users[]=$user;
		}
	}

	$cDB = $cont->get(CalDavBackend::class);

	foreach( $users as $user )
	{
		// Ignore errors for now
		$dir = $outpath . "/" . $user . "/files/sysbackup/calendars";
		if( ! is_dir( $dir ))
		{
			mkdir( $dir , 0700, true);
		}
		if( ! is_dir( $dir ) )
		{
			continue;
		}

		$calendars = $cDB->getCalendarsForUser("principals/users/$user");

		foreach( $calendars as $calendar)
		{
			$filename = $dir . '/' . str_replace(' ', '-', $calendar['uri']) . '.ics';
			$calobjs = $cDB->getCalendarObjects($calendar["id"]);
			$calstr = "";
			foreach( $calobjs as $cobj )
			{
				$caldata = $cDB->getCalendarObject( $calendar["id"], $cobj["uri"]);
				$calstr  .= $caldata["calendardata"]."\n";
			}

			file_put_contents( $filename, $calstr);
		}
	}
}
catch( Exception $e)
{
	print "Export failed: ".$e->getMessage()."\n";
}
