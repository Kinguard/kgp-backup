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
import pykgpconfig
from pylibopi import AuthLogin,BackupRootPath
import psutil

AUTH_SERVER        = "auth.openproducts.com"
AUTH_PATH        = "/"
QUOTA_FILE        = "quota.php"
CURR_DIR = os.path.dirname(os.path.realpath(__file__))
SYSINFO="/etc/opi/sysinfo.conf"
BACKUP_TARGET = "/var/opi/etc/backup/target.conf"
BACKUP_CONF   = CURR_DIR+"/backup.conf"
MOUNT_SCRIPT = CURR_DIR+"/mount_fs.sh"
#TODO: more errorchecking

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
        sysinfo = pykgpconfig.read_config(SYSINFO)
    except Exception as e:
        dprint("Failed to read sys config")
        dprint(e)
        terminate(1)

    try:
        backup_config = pykgpconfig.read_config(BACKUP_CONF)
    except Exception as e:
        dprint("Failed to read backup config")
        dprint(e)
        terminate(1)


    if 'target_file' not in backup_config:
        dprint("Missing parameters in backup config")
        terminate(1)

    try:
        target_config = pykgpconfig.read_config(backup_config['target_file'])
    except Exception as e:
        dprint("Failed to read target config")
        dprint(e)
        terminate(1)
	
    if 'backend' not in target_config:
        dprint("Missing backend in target file")
        terminate(1)
    backend = target_config['backend']

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
                ctx.load_verify_locations( sysinfo["ca_path"] )
            except Exception as e:
                dprint("CA file error")
                dprint(e)
                terminate(1)

            conn = http.client.HTTPSConnection(AUTH_SERVER, 443, context=ctx)

            qs = urllib.parse.urlencode({'unit_id':sysinfo["unit_id"]}, doseq=True)
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
        BackupRootPath = BackupRootPath()
        dprint("BackupRootPath: %s" % BackupRootPath)

        response = {}
        response['quota'] = 0
        response['bytes_used'] = 0
        response['mounted'] = False

        partitions = psutil.disk_partitions(all=True)
        for p in partitions:
            if ( BackupRootPath in p.mountpoint ):
                disk_usage=psutil.disk_usage(p.mountpoint)
                # usage seems to be reported in 1k blocks, not as bytes as documentation says...
                if (backend == "local://"):
                    response['quota'] = int(psutil.disk_usage(backup_config['device_mountpath']).total)
                response['bytes_used'] = int(disk_usage.used)
                response['mounted'] = True
                break


    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))



