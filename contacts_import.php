<?php
/*
* Based mostly upon importcontroller.php Copyright (c) 2013 Thomas Tanghus (thomas@tanghus.net)
*/

set_time_limit(0);

require_once "lib/base.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

OCP\App::checkAppEnabled('contacts');

echo "App enabled\n";

use OCA\Contacts\VObject\VCard as MyVCard;
use OCA\Contacts\App;
use Sabre\VObject;

$inpath = ".";

if( count( $argv ) >= 2 )
{
	$inpath = $argv[1];
}

echo "Using inpath: $inpath\n";

function import($filename, $user, $app, $bookid)
{
	echo "Importing $filename into $bookid\n";
	$addressBook = $app->getAddressBook('local', $bookid);
	if(!$addressBook->hasPermission(\OCP\PERMISSION_CREATE)) {
		return false;
	}

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
		try {
			$vcard = VObject\Reader::read($part);
		} catch (VObject\ParseException $e) {
			try {
				$vcard = VObject\Reader::read($part, VObject\Reader::OPTION_IGNORE_INVALID_LINES);
				$partially += 1;
				echo 'Import: Retrying reading card. Error parsing VCard: ' . $e->getMessage() . '\n';
			} catch (\Exception $e) {
				$failed += 1;
				echo 'Import: skipping card. Error parsing VCard: ' . $e->getMessage() . '\n';
				continue; // Ditch cards that can't be parsed by Sabre.
			}
		}
		try {
			$vcard->validate(MyVCard::REPAIR|MyVCard::UPGRADE);
		} catch (\Exception $e) {
			echo 'Error validating vcard: ' . $e->getMessage() . '\n';
			$failed += 1;
		}

		try {
			if($addressBook->addChild($vcard)) {
				$imported += 1;
			} else {
				$failed += 1;
			}
		} catch (\Exception $e) {
			echo 'Error importing vcard: ' . $e->getMessage() . $nl . $vcard->serialize() .'\n';
			$failed += 1;
		}
		$processed += 1;
	}

	/* Probably not needed
	if( !\OCP\Config::setUserValue($user, 'contacts', 'lastgroup', 'all') )
	{
		echo "Failed to set config user value\n";
	}

	\OCA\Contacts\Hooks::indexProperties();
	*/

	echo "Imported $imported contacts $partially partially and $failed failed\n";

	return true;
}



$dirs = glob($inpath ."/*", GLOB_ONLYDIR | GLOB_NOSORT);

foreach( $dirs as $dir )
{
	$user = pathinfo( $dir, PATHINFO_BASENAME );
	
	OC_User::setUserId($user);

	$app = new App($user);

	$backend = $app->getBackend("local");
	if(!$backend->hasAddressBookMethodFor(\OCP\PERMISSION_CREATE)) {
		echo 'This backend does not support adding address books';
		break;
	}

	$books = glob( $dir . "/files/sysbackup/contacts/*", GLOB_NOSORT );

	foreach( $books as $book )
	{
		if( ! is_file( $book ) )
		{
			continue;
		}
		$name = pathinfo( $book, PATHINFO_BASENAME);
		echo "User $user has book $name\n";

		$id = $backend->createAddressBook(['displayname' => "Imported_" . pathinfo($name,PATHINFO_FILENAME) ]);
		
		if ( $id === false )
		{
			echo "Failed to create address book\n";
			break;
		}

		if( ! import( $book, $user, $app, $id) )
		{
			echo "Failed to import $name\n";
			// For now delete failed import
			$backend->deleteAddressBook( $id );
		}
	}
}
