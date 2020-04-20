#! /usr/bin/env python3

import os
import re
import json
import shutil
import textwrap
import argparse
from syslog import *
from datetime import *
from dateutil.parser import parse

openlog("expirebackup",LOG_PERROR, LOG_DAEMON)

def log(msg):
	syslog( LOG_INFO, msg )

def err(msg):
	syslog( LOG_ERR, msg )

def debug(msg):
	syslog( LOG_DEBUG, msg)


parser = argparse.ArgumentParser(
	formatter_class=argparse.ArgumentDefaultsHelpFormatter,
	description=textwrap.dedent('''\
	kgp expire backups

	Expire config is stored in a json file with the
	following syntax

	{
		"backup":{
		"expire":
		[
			[ 1, 2, -1], Last two weeks, keep everything
			[ 3, 7, 5] Following 5 week, keep one from each week
		]
		}
	}

	Each tuple is made up with
	start and stop of interval and the number of
	backups to keep for the interval. An amount <0
	indicates keep all in interval.

	Note that the file is ordered backwards i.e.
	now and back in time
	'''))

parser.add_argument('-c','--config', default="/etc/kinguard/backupconfig.json", help="Expire config file")
parser.add_argument('-s','--status', action="store_true", help="Show current situation without action")
parser.add_argument('-d','--debug', action="store_true", help="Debug logging")
#parser.add_argument('-t','--test', action="store_true", help="Debug testing")
parser.add_argument('-S', '--start', help="Use START date instead of current date when processing backups")
parser.add_argument('--s3ql', action="store_true", help="Use s3qlrm to remove backups")
parser.add_argument('path' ,help="Path to directory containing backups to be processed")

args=parser.parse_args()

if args.debug:
	setlogmask(LOG_UPTO(LOG_DEBUG))
else:
	setlogmask(LOG_UPTO(LOG_INFO))

debug("Using config: %s" % args.config)

cfgfile=open(args.config)
cfg=json.load(cfgfile)
cfgfile.close()

intervals = cfg["backup"]["expire"]

# "Constants" to use
if args.start:
	now = parse(args.start)
else:
	now = datetime.now().replace(microsecond=0)
debug("Using start date %s" % now)

week = timedelta(7)
s3qlrm="/usr/bin/s3qlrm"

if args.s3ql and not os.access(s3qlrm, os.X_OK):
	err("s3ql usage requested but s3qlrm executable not available")
	exit(-1)


# https://stackoverflow.com/questions/304256/whats-the-best-way-to-find-the-inverse-of-datetime-isocalendar
def iso_year_start(iso_year):
	"The gregorian calendar date of the first day of the given ISO year"
	fourth_jan = date(iso_year, 1, 4)
	delta = timedelta(fourth_jan.isoweekday()-1)
	return fourth_jan - delta

def iso_to_gregorian(iso_year, iso_week, iso_day):
	"Gregorian calendar date for the given ISO year, week and day"
	year_start = iso_year_start(iso_year)
	return year_start + timedelta(days=iso_day-1, weeks=iso_week-1)


# Debug and test functions
import pprint

pp = pprint.PrettyPrinter(indent=4)
def createdir( dr ):
	if not os.path.exists( args.path+"/"+dr ):
		os.mkdir( args.path+"/"+dr )

def setuptest(start = datetime(2018,12,27,12,34), stop = now):
	createdir("")

	while start < now:
		dr = start.isoformat('_')
		createdir(dr)
		start += timedelta(1)
# end debug and test


# Determine available backups in path
def	getbackups( path ):

	return set(x for x in os.listdir(path)
		if re.match(r'^\d{4}-\d\d-\d\d_\d\d:\d\d:\d\d$', x))



# Convert to datetimes
def stringtodatetime( dirs ):
	bts=[]
	for backup in dirs:
		(dt,tm) = backup.split("_")
		bts.append(parse(dt+" "+tm))
	return bts



# Sort backups on year and week number
# returns dict with [year][week]:list of backups
def datesort( backups ):
	res = {}

	for backup in backups:
		if backup > now:
			#debug("Backup from the future %s, skipping" % backup)
			continue
		(year, week, day) = backup.isocalendar()
		if year not in res:
			res[year]={}

		if week not in res[year]:
			res[year][week] = []

		res[year][week].append(backup)

	return res

# Find all iso year and weeknumbers
# in span of start to stop in reverse.
# i.e. start is younger than stop
def weektoiso( start, stop):
	ret = []

	for relweek in range(start, stop+1):
		(yr, wk, day) = (now - (relweek-1)*week).isocalendar()
		ret.append([yr,wk])

	return ret


# Retrieve all backups in a week interval
def backupsininterval( db, start, stop ):
	ret = []

	isodates = weektoiso( start, stop)

	for date in isodates:
		debug(" Year: %d week %d" % (date[0], date[1]))
		try:
			ret+=db[date[0]][date[1]]
		except KeyError:
			pass

	return ret

# Sort backups into intervals
# returns array with key interval and value list of backup dates as datetimes
def sortbackups(db):
	debug("Sort backups")
	sort = {}
	for i, ival in enumerate(intervals):
		debug("Process interval %d - %d (%d)" % (ival[0], ival[1], ival[2]))
		isoend = (now - (ival[0])*week).isocalendar()
		end = datetime.combine(iso_to_gregorian( isoend[0], isoend[1], 7), time.max)
		start = (now - (ival[1])*week).replace(hour=0,minute=0,second=0)

		sort[i] = {}
		sort[i]["start"] = start
		sort[i]["end"] = end
		sort[i]["backups"] = sorted(backupsininterval(db, ival[0], ival[1]))
	#debug("Sort backups done")
	return sort



# Weed out all but mx backups from backups
# Backups, list of datetimes of backup
# MX, max backups to keep
def weedsingle(backups, mx):

	start = backups["start"]
	end = backups["end"]
	backups = backups["backups"]

	debug("Weed all but %d backups" % mx)
	ret = []
	nbk = len(backups)
	stp = int(nbk/mx)

	i_total_days = ( end - start).days+1
	i_days = round(i_total_days / (mx))

	# find backup closest to keep for each interval point
	keep = start
	while keep <= end:
		ipoint = keep + timedelta( i_days/2)

		closest = [None, timedelta.max.total_seconds()]
		for backup in backups:
			delta = round(abs((ipoint - backup).total_seconds()))
			if( delta < closest[1] ):
				closest = [backup, delta]
		backups.remove(closest[0])
		keep += timedelta(i_days)

	return backups


# Return list with backups that should be removed
def weed( backups ):
	ret = []
	for key in backups:
		mxb = intervals[key][2]
		bcnt = len(backups[key]["backups"])
		debug("Process range %d with %d backups keep %d" % (key, bcnt, mxb))

		if mxb < 0:
			debug("Nothing to do, keep all")
			continue

		if mxb >= bcnt or bcnt == 0:
			debug("Nothing to do")
			continue

		ret+=weedsingle(backups[key],mxb)

	return ret


def remove( backups ):

	for b in backups:
		dr = b.strftime("%Y-%m-%d_%H:%M:%S")
		bpath=args.path+"/"+dr
		if args.s3ql:
			debug("Remove %s using s3qlrm"%bpath)
			os.system( s3qlrm+" "+bpath )
			pass
		else:
			debug("Remove %s"%bpath)
			shutil.rmtree(bpath)

def dumpstatus():
		backup_list = getbackups(args.path)

		btimes= stringtodatetime( backup_list)

		db = datesort( btimes )
		ibackups = sortbackups(db)

		print("Available backups in intervals - begin")
		pp.pprint(ibackups)
		print("Available backups - end")

def main():

	if args.status:
		dumpstatus()
		exit(0)

#	if args.test:
#		setuptest()

	backup_list = getbackups(args.path)

	btimes = stringtodatetime( backup_list )

	db = datesort( btimes )

	if args.debug:
		pp.pprint(db)

	ibackups = sortbackups(db)

	if args.debug:
		print("ibackups - begin")
		pp.pprint(ibackups)
		print("ibackups - end")

	to_rm=weed(ibackups)

	remove(to_rm)

if __name__ == '__main__':
    main()



