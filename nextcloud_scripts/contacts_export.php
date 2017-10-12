<?php
use OCA\DAV\AppInfo\Application;
use OCA\DAV\CardDAV\CardDavBackend;

set_time_limit(0);

require_once "lib/base.php";
require_once "/usr/share/php/PhpSecop/Secop.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

OCP\App::checkAppEnabled('contacts');

$outpath = ".";

if( count( $argv ) >= 2 )
{
	$outpath = $argv[1];
}

echo "Using outpath: $outpath\n";

// Get any possible none OP users
$users = OCP\User::getUsers();

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

$app = new Application();
$cDB = $app->getContainer()->query(CardDavBackend::class);

foreach( $users as $user )
{
	echo "Exporting contacts for user $user\n";
	
	// Ignore errors for now
	$dir = $outpath . "/" . $user . "/files/sysbackup/contacts";
	mkdir( $dir , 0700, true);
	if( ! is_dir( $dir ) )
	{
		echo "Failed to create directory: $dir\n";
		continue;
	}

	$books = $cDB->getAddressBooksForUser("principals/users/$user");

	foreach( $books as $book )
	{
		$filename = $dir . '/' . str_replace(' ', '_', $user."_".$book["uri"]) . '.vcf';
		echo "File: $filename\n";

		$cards = $cDB->getCards( $book["id"] );

		$contacts = '';
		foreach($cards as $contact) {
			$contacts .= $contact["carddata"]."\n";
		}

		file_put_contents( $filename, $contacts);
	}
}
