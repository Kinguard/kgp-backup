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

$app = new Application();
$cont = $app->getContainer();
$app_mgr = $cont->get(AppManager::class);

if( ! $app_mgr->isInstalled('contacts') )
{
	print "Calendar not installed!\n";
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

	$cDB = $cont->get(CardDavBackend::class);

	foreach( $users as $user )
	{
		$dir = $outpath . "/" . $user . "/files/sysbackup/contacts";
		if( ! is_dir( $dir ))
		{
			mkdir( $dir , 0700, true);
		}
		if( ! is_dir( $dir ) )
		{
			echo "Failed to create directory: $dir\n";
			continue;
		}

		$books = $cDB->getAddressBooksForUser("principals/users/$user");
		foreach( $books as $book )
		{
			$filename = $dir . '/' . str_replace(' ', '_', $user."_".$book["uri"]) . '.vcf';

			$cards = $cDB->getCards( $book["id"] );
			$contacts = '';
			foreach($cards as $contact) {
				$contacts .= $contact["carddata"]."\n";
			}

			file_put_contents( $filename, $contacts);
		}
	}
}
catch( Exception $e)
{
	print "Export failed: ".$e->getMessage()."\n";
}
