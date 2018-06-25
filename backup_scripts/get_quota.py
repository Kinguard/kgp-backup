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
    #response['status'] = "Fail"
    
    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))
    sys.exit(status)
		

### -------------- MAIN ---------------
if __name__=='__main__':

    parser = argparse.ArgumentParser()
    parser.add_argument("-t", "--type", default="json", help="Output format type, "
                    "valid options are json and sh, defaults to json")
    parser.add_argument("-d", "--debug", help="Enable debug prints",action="store_true")

    args = parser.parse_args()



    try:
        unitid = GetKeyAsString("hostinfo","unitid")
        dprint("UnitID: %s" % unitid)
    except Exception as e:
        dprint("Failed to read 'unitid' parameter")
        dprint(e)
        terminate(1)
    try:
        backend = GetKeyAsString("backup","backend")
    except Exception as e:
        dprint("Failed to read 'backend' parameter")
        dprint(e)
        terminate(1)

    if (backend == "s3op://") or (backend == "none"):
        #report server quota even if service is not active.
        token = AuthLogin()
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
                response = {}
                response['quota'] = int(j_resp['quota'][:-2])*1024
                response['bytes_used'] = int(int(j_resp['bytes_used'])/1024)
                response['Code'] = conn.status
            else:
                j_resp = json.loads(r.read().decode("utf-8"))
                response = {}
                # quota reported in GB, i.e. 8GB, report pass along as in bytes
                response['quota'] = int(j_resp['quota'][:-2])*1024*1024*1024
                response['bytes_used'] = int(int(j_resp['bytes_used']))
                response['Code'] = 200

        except http.client.HTTPException as e:
            dprint(e)

    else:

        response = {}
        response['quota'] = 0
        response['bytes_used'] = 0
        response['mounted'] = False

        partitions = psutil.disk_partitions(all=True)
        devicepath = GetKeyAsString("backup","devicemountpath")

        for p in partitions:
            if ( devicepath in p.mountpoint ):
                disk_usage=psutil.disk_usage(p.mountpoint)
                # usage seems to be reported in 1k blocks, not as bytes as documentation says...
                if (backend == "local://"):
                    response['quota'] = int(psutil.disk_usage(devicepath).total)
                response['bytes_used'] = int(disk_usage.used)
            
            if ( BackupRootPath() in p.mountpoint ):
                response['mounted'] = True


    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))



