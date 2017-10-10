<?php
/*
* Based mostly upon importcontroller.php Copyright (c) 2013 Thomas Tanghus (thomas@tanghus.net)
*/

set_time_limit(0);
ini_set('display_errors', 'On');
error_reporting(E_ALL);


function makeuri()
{
	// simple GUID with .vcf suffix
	return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x.vcf', mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(16384, 20479), mt_rand(32768, 49151), mt_rand(0, 65535), mt_rand(0, 65535), mt_rand(0, 65535));
}

require_once "lib/base.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

OCP\App::checkAppEnabled('contacts');

echo "App enabled\n";

use OCA\DAV\AppInfo\Application;
use OCA\DAV\CardDAV\CardDavBackend;

$inpath = ".";

if( count( $argv ) >= 2 )
{
	$inpath = $argv[1];
}

echo "Using inpath: $inpath\n";

function import($filename, $user, $cdb, $bookid)
{
	echo "Importing $filename into $bookid\n";

	$file = file_get_contents( $filename );

	$nl = "\n";
	$file = str_replace(array("\r","\n\n"), array("\n","\n"), $file);
	$lines = explode($nl, $file);

	$inelement = false;
	$parts = array();
	$card = array();
	foreach($lines as $line) {
		if(strtoupper(trim($line)) == 'BEGIN:VCARD') {
			$inelement = true;
		} elseif (strtoupper(trim($line)) == 'END:VCARD') {
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
		echo "No contacts found in: $filename\n";
		return false;
	}
	//import the contacts
	$imported = 0;
	$failed = 0;
	$partially = 0;
	$processed = 0;

	foreach($parts as $part) {
		try
		{
			$uri = makeuri();
			if( $cdb->createCard( $bookid, $uri, $part ) != null )
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
			print "Import card failed ".$e->getMessage()."\n";
			$failed += 1;
		}
		$processed += 1;
	}

	echo "Imported $imported contacts $partially partially and $failed failed\n";

	return true;
}


try
{

	$dirs = glob($inpath ."/*", GLOB_ONLYDIR | GLOB_NOSORT);


	$app = new Application();
	$cDB = $app->getContainer()->query(CardDavBackend::class);


	foreach( $dirs as $dir )
	{
		$user = pathinfo( $dir, PATHINFO_BASENAME );

		OC_User::setUserId($user);

		$books = glob( $dir . "/files/sysbackup/contacts/*", GLOB_NOSORT );

		foreach( $books as $book )
		{
			if( ! is_file( $book ) )
			{
				continue;
			}
			$name = pathinfo( $book, PATHINFO_BASENAME);
			$displayname = "Imported_" . pathinfo($name,PATHINFO_FILENAME);
			echo "User $user has book $name\n";

			$id = $cDB->createAddressBook("principals/users/$user",$displayname,['{DAV:}displayname' => $displayname  ]);
			if ( $id === false )
			{
				echo "Failed to create address book\n";
				break;
			}

			if( ! import( $book, $user, $cDB, $id) )
			{
				echo "Failed to import $name\n";
				// For now delete failed import
				$cDB->deleteAddressBook( $id );
			}
		}
	}
}
catch( Exception $e)
{
	print "Failed to import addressbook: ".$e->getMessage()."\n";
}
