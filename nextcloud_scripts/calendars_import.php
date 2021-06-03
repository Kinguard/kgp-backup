<?php
set_time_limit(0);

function makeuri()
{
	// simple GUID with .ics suffix
	return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x.ics', mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(16384, 20479), mt_rand(32768, 49151), mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535));
}


function import($filename, $cdb, $calid)
{
	echo "Importing $filename into $calid\n";

	$file = file_get_contents( $filename );

	$nl = "\n";
	$file = str_replace(array("\r","\n\n"), array("\n","\n"), $file);
	$lines = explode($nl, $file);
	$inelement = false;
	$parts = array();
	$card = array();
	foreach($lines as $line) {
		if(strtoupper(trim($line)) == 'BEGIN:VCALENDAR') {
			//$card[] = $line;
			$inelement = true;
		} elseif (strtoupper(trim($line)) == 'END:VCALENDAR') {
			$card[] = $line;
			$parts[] = implode($nl, $card);
			$card = array();
			$inelement = false;
		}
		if ($inelement === true && trim($line) != '') {
			$card[] = $line;
		}
	}

	if(count($parts) === 0) {
		echo "No events found in: $filename\n";
		return false;
	}

	print "Read ".count($parts)." possible events\n";

	//import events
	$imported = 0;
	$failed = 0;
	$partially = 0;
	$processed = 0;
	foreach($parts as $part) {
		try
		{
			$uri = makeuri();
			if( $cdb->createCalendarObject( $calid, $uri, $part ) != null )
			{
				$imported += 1;
			}
			else
			{
				$failed += 1;
			}
		}
		catch( Exception $e )
		{
			print "Import event failed ".$e->getMessage()."\n";
			$failed += 1;
		}
		$processed += 1;
	}

	echo "Imported $imported event $partially partially and $failed failed\n";

	return true;
}



require_once "lib/base.php";

use OCA\DAV\AppInfo\Application;
use OCA\DAV\CalDAV\CalDavBackend;

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

echo "Calendar enabled\n";


$inpath = ".";
if( count( $argv ) >= 2 )
{
	$inpath = $argv[1];
}

echo "Using inpath: $inpath\n";

$dirs = glob($inpath ."/*", GLOB_ONLYDIR | GLOB_NOSORT);

print_r($dirs);

$cDB = $cont->get(CalDavBackend::class);

print "Got cdb\n";


foreach( $dirs as $dir )
{
	$user = pathinfo( $dir, PATHINFO_BASENAME );

	print "Process $user\n";

	$calendars = glob( $dir . "/files/sysbackup/calendars/*", GLOB_NOSORT );

	$colind = 1;

	foreach( $calendars as $calendar )
	{
		if( ! is_file( $calendar ) )
		{
			continue;
		}

		$name = pathinfo( $calendar, PATHINFO_BASENAME);
		$calname = "Imported_" . pathinfo($name,PATHINFO_FILENAME);

		$id = $cDB->createCalendar("principals/users/$user", $calname, []);

		if( ! import( $calendar, $cDB, $id) )
		{
			echo "Failed to import $name\n";
			// For now delete failed import
			$cDB->deleteCalendar( $id );
		}

	}
}


