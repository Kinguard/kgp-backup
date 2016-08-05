<?php
set_time_limit(0);

require_once "lib/base.php";

if (!OC::$CLI) {
	echo "This script can be run from the command line only" . PHP_EOL;
	exit(0);
}

OCP\App::checkAppEnabled('contacts');

echo "App enabled\n";

use OCA\Contacts\App;

$outpath = ".";

if( count( $argv ) >= 2 )
{
	$outpath = $argv[1];
}

echo "Using outpath: $outpath\n";

$users = OCP\User::getUsers();

foreach( $users as $user )
{
	echo "User: $user\n";
	// Ignore errors for now
	$dir = $outpath . "/" . $user . "/contacts";
	mkdir( $dir , 0700, true);
	if( ! is_dir( $dir ) )
	{
		echo "Failed to create directory: $dir\n";
		continue;
	}

	$app = new App($user);

	$books = $app->getAddressBooksForUser();

	foreach( $books as $book )
	{
		$filename = $dir . '/' . str_replace(' ', '_', $book->getDisplayName()) . '.vcf';
		echo "File: $filename\n";

		$contacts = '';
		foreach($book->getChildren() as $i => $contact) {
			$contacts .= $contact->serialize() . "\r\n";
		}

		file_put_contents( $filename, $contacts);
	}
}
