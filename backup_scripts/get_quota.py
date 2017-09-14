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
from pylibopi import AuthLogin

AUTH_SERVER        = "auth.openproducts.com"
AUTH_PATH        = "/"
QUOTA_FILE        = "quota.php"

SYSINFO="/etc/opi/sysinfo.conf"
BACKUP_TARGET = "/var/opi/backup_target.conf"
BACKUP_CONF   = "/usr/share/opi-backup/backup.conf"

MOUNT_SCRIPT = "/usr/share/opi-backup/mount_fs.sh"
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
            response = r.read().decode("utf-8")

        except http.client.HTTPException as e:
            dprint(e)

    elif backend == "local://":
    	
        if 'backupdisk' not in backup_config:
            dprint("Missing backupdisk in backup config file")
            terminate(1)
    	
        #Try to mount the disk
        try:
            FNULL = open(os.devnull, 'w')
            retcode = subprocess.call(MOUNT_SCRIPT, stdout=FNULL, stderr=subprocess.STDOUT)
            if not retcode:
                df = subprocess.Popen(["df", backup_config['backupdisk']], stdout=subprocess.PIPE)
                output = df.communicate()[0].decode()
                device, size, used, available, percent, mountpoint = \
                output.split("\n")[1].split()
                response = {}
                response['quota'] = int(size) * 1024
                response['bytes_used'] = int(used) * 1024
                response['mounted'] = True
            else:
                response = {}
                response['quota'] = 0
                response['bytes_used'] = 0
                response['mounted'] = False
        except Exception as e:
            dprint("Error mounting disk")
            dprint(e)
            terminate(1)

    elif backend == "s3://":

        if 'backup_mntpoint' not in backup_config:
            dprint("Missing backup_mntpoint in backup config file")
            terminate(1)
        mountpoint = backup_config['backup_mntpoint']

        try:
            if not os.path.ismount(mountpoint):
                #Try to mount the disk
                try:
                    dprint("Trying to mount backend")
                    FNULL = open(os.devnull, 'w')
                    retcode = subprocess.call(MOUNT_SCRIPT, stdout=FNULL, stderr=subprocess.STDOUT)
                    if retcode:
                        dprint("Error mounting S3 backend")    
                        terminate(1)
                except Exception as e:
                    dprint("Error mounting S3 backend")
                    dprint(e)
                    terminate(1)

            df = subprocess.Popen(["df", mountpoint], stdout=subprocess.PIPE)
            output = df.communicate()[0].decode()
            device, size, used, available, percent, mountpoint = \
            output.split("\n")[1].split()
            response = {}
            response['quota'] = 0
            response['bytes_used'] = int(used) * 1024
            response['mounted'] = True
        except  Exception as e:
            dprint("Error getting quota for s3 backend")
            dprint(e)
            terminate(1)
            
            
    else:
        dprint("Unknown backend, exit")
        terminate(1)


    if args.type == "sh":
        #dprint("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #dprint(response)
        print(json.dumps(response))


