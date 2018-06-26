#!/usr/bin/python3
import urllib.parse
import json
from base64 import b64encode
import hashlib
from OpenSSL import crypto
import configparser
import sys
import argparse
import subprocess
import os
from pylibopi import AuthLogin,BackupRootPath,GetKeyAsString
import psutil

AUTH_SERVER        = "auth.openproducts.com"
AUTH_PATH        = "/"
QUOTA_FILE        = "quota.php"
CURR_DIR = os.path.dirname(os.path.realpath(__file__))
MOUNT_SCRIPT = CURR_DIR+"/mount_fs.sh"
CACHED_QUOTA = "/var/opi/etc/backup/quota.cache"
# Constants used on serverside
FAIL        = 0
SUCCESS        = 1
WAIT        = 2
REQUEST_KEY    = 3


def dprint(line):
	if args.debug:
		print(line)

def terminate(status):
    response = {}
    response['quota'] = 0
    response['bytes_used'] = 0
    response['mounted'] = False
    response['status'] = not status
    
    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))
    sys.exit(status)
	
def readcache(backend):
    try:
        conf = open(CACHED_QUOTA,"r")
        config = json.loads(conf.read())
        conf.close()
    except Exception as e:
        dprint("Failed to read config file")
        terminate(1)
    return config[backend]

def writecache(stats):
    try:
        dprint("Open config file")
        conf = open(CACHED_QUOTA,"r")
    except IOError:
        config = {}
    except Exception as e:
        dprint("Failed to open config file")
        dprint(e)
        terminate(1)

    try:
        dprint("Reading config")
        filecontent = conf.read()
        conf.close()
    except Exception as e:
        dprint("Failed to read config file")
        dprint(e)
        terminate(1)

    try:
        dprint("Parsing file content")
        config = json.loads(filecontent)
    except:
        dprint("Could not parse config file content, writing new content")
        config = {}

    config[stats['backend']] = stats
    try: 
        dprint("Open config file")
        conf = open(CACHED_QUOTA,"w")
    except Exception as e:
        dprint("Failed to open config file for writing")
        dprint(e)
        terminate(1)

    dprint("Writing config file")
    try:
        conf.write(json.dumps(config))
        conf.close()
    except Exception as e:
        dprint("Failed to write config file")
        dprint(e)




### -------------- MAIN ---------------
if __name__=='__main__':

    parser = argparse.ArgumentParser()
    parser.add_argument("-t", "--type", default="json", help="Output format type, "
                    "valid options are json and sh, defaults to json")
    parser.add_argument("-d", "--debug", help="Enable debug prints",action="store_true")

    args = parser.parse_args()

    response = {}
    response['quota'] = 0
    response['bytes_used'] = 0
    response['mounted'] = False
    response['valid'] = False


    try:
        unitid = GetKeyAsString("hostinfo","unitid")
        dprint("UnitID: %s" % unitid)
    except Exception as e:
        dprint("Failed to read 'unitid' parameter")
        dprint(e)
        terminate(1)
    try:
        backend = GetKeyAsString("backup","backend")
        response['backend'] = backend
    except Exception as e:
        dprint("Failed to read 'backend' parameter")
        dprint(e)
        terminate(1)

    if (backend == "s3op://") or (backend == "none"):
        #report server quota even if service is not active.
        try:
            token = AuthLogin()
        except Exception as e:
            dprint("Authentication failed")
            dprint(e)
            terminate(1)
        try:
            import ssl
            import http.client

            ctx = ssl.SSLContext(ssl.PROTOCOL_SSLv23)

            ctx.options |= ssl.OP_NO_SSLv2
            ctx.verify_mode = ssl.CERT_REQUIRED

            try:
                ctx.load_verify_locations( GetKeyAsString("hostinfo","cafile") )
            except Exception as e:
                dprint("CA file error")
                dprint(e)
                terminate(1)

            conn = http.client.HTTPSConnection(AUTH_SERVER, 443, context=ctx)

            qs = urllib.parse.urlencode({'unit_id':unitid}, doseq=True)
            path = urllib.parse.quote(AUTH_PATH + QUOTA_FILE) + "?"+qs
            headers = {}
            headers["token"] = token
            conn.request( "GET", path, None, headers)

            r = conn.getresponse()
            if (r.status != 200):
                # TODO: why do we set data that most likely is not accessible???
                response['quota'] = int(j_resp['quota'][:-2])*1024
                response['bytes_used'] = int(int(j_resp['bytes_used'])/1024)
                response['Code'] = conn.status
            else:
                j_resp = json.loads(r.read().decode("utf-8"))
                # quota reported in GB, i.e. 8GB, report pass along as in bytes
                response['quota'] = int(j_resp['quota'][:-2])*1024*1024*1024
                response['bytes_used'] = int(int(j_resp['bytes_used']))
                response['Code'] = 200

        except http.client.HTTPException as e:
            dprint(e)

    elif (backend == "local://"):

        partitions = psutil.disk_partitions(all=False) # only get physical devices
        devicepath = GetKeyAsString("backup","devicemountpath")

        for p in partitions:
            if ( devicepath in p.mountpoint ):
                disk_usage=psutil.disk_usage(p.mountpoint)
                dprint(disk_usage)
                # usage seems to be reported in 1k blocks, not as bytes as documentation says...
                response['quota'] = int(psutil.disk_usage(devicepath).total)
                response['bytes_used'] = int(disk_usage.used)
                response['valid'] = True
            if ( BackupRootPath() in p.mountpoint ):
                response['mounted'] = True
        if (not response['valid']):
            dprint("Disk not found / mounted")
    else:
        partitions = psutil.disk_partitions(all=True)
        for p in partitions:
            if ( BackupRootPath() in p.mountpoint ):
                dprint("Found mounted backup")
                try:
                    output = subprocess.check_output(["/usr/lib/s3ql/s3qlstat","--raw",p.mountpoint]).decode("utf-8")
                    stats=dict(item.strip().split(":") for item in output.splitlines())
                    stats['backend'] = backend
                    response['bytes_used'] = int(stats['Total data size'].split()[0]) + int(stats['Database size'].split()[0])
                    response['valid'] = True
                    response['mounted'] = True
                    writecache(stats)
                except Exception as e:
                    dprint("s3qlstat failed.")
                break
        if (not response['valid']):
            dprint("Backend not mounted, trying cached data")
            stats = readcache(backend)
            response['bytes_used'] = int(stats['Total data size'].split()[0]) + int(stats['Database size'].split()[0])
            response['valid'] = False



    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))



