#! /usr/bin/env python3

import os
import re
import shutil
from syslog import *
from datetime import *
from dateutil.parser import parse

# Interval in weeks, should be sorted
# from now and back in time
# 1 - this week
# 2 - last week etc
#
# example
# intervals = [
#   [1,1], This week
#   [2,3], last week and third week from now

intervals =[
	#Start	stop	nr to keep. <0 keep all
	[1,		1,		-1],
	[2,		2,		-1],
	[3,		6,		4],
	[7,		10,		1],
	[11,	14,		1],
	[15,	19,		1],
	[20,	52,		32],
]

openlog("expirebackup",LOG_PERROR, LOG_DAEMON)
#setlogmask(LOG_UPTO(LOG_DEBUG))
setlogmask(LOG_UPTO(LOG_INFO))


def log(msg):
	print(msg)
#	syslog( LOG_INFO, msg )

def err(msg):
	print(msg)
#	syslog( LOG_ERR, msg )

def debug(msg):
	print(msg)
	#syslog( LOG_DEBUG, msg)


# "Constants" to use
now = datetime.now().replace(microsecond=0)
week = timedelta(7)


# Debug and test functions

import pprint
pp = pprint.PrettyPrinter(indent=4)

WD="./testdir"

def createdir( dr ):
	if not os.path.exists( WD+"/"+dr ):
		os.mkdir( WD+"/"+dr )

def inint( val, start, stop):
	return start <= val <= stop

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
def sortbackups(db):
	sort = {}
	for i, ival in enumerate(intervals):
		debug("Process interval %d - %d (%d)" % (ival[0], ival[1], ival[2]))
		start = (now - (ival[0]-1)*week)
		end = (now - (ival[1]-1)*week)
		sort[i] = sorted(backupsininterval(db, ival[0], ival[1]))
	return sort



# Weed out all but mx backups from backups
def weedsingle(backups, mx):
	print("Weed all but %d backups" % mx)
	ret = []
	nbk = len(backups)
	stp = int(nbk/mx)

	for x in range(1, nbk+1):
		if x%stp != 0:
			ret.append(backups[x-1])

	return ret


# Return list with backups that should be removed
def weed( backups ):
	ret = []
	for key in backups:
		mxb = intervals[key][2]
		bcnt = len(backups[key])
		debug("Process %d with %d backups keep %d" % (key, bcnt, mxb))

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
		#debug("Remove "+WD+"/"+dr)
		shutil.rmtree(WD+"/" +dr)

setuptest()

backup_list = getbackups(WD)

btimes = stringtodatetime( backup_list )

db = datesort( btimes )

pp.pprint(db)

ibackups = sortbackups(db)

print("ibackups - begin")
pp.pprint(ibackups)
print("ibackups - end")

to_rm=weed(ibackups)

#print("to-remove-start")
#pp.pprint(to_rm)
#print("to-remove-end")

remove(to_rm)


backup_list = getbackups(WD)

btimes= stringtodatetime( backup_list)

db = datesort( btimes )

print("\n\n---- updated ----\n\n")
#pp.pprint(db)

ibackups = sortbackups(db)

print("ibackups updated - begin")
pp.pprint(ibackups)
print("ibackups updated - end")



