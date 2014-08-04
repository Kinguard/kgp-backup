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

AUTH_SERVER        = "auth.openproducts.com"
AUTH_PATH        = "/"
AUTH_FILE        = "auth.php"
DNS_FILE        = "update_dns.php"

SYSINFO            = "/etc/opi/sysinfo.conf"
BACKUP_TARGET = "/etc/opi/backup_target.conf"
BACKUP_CONF   = "/usr/share/opi-backup/backup.conf"

MOUNT_SCRIPT = "/usr/share/opi-backup/mount_fs.sh"
#TODO: more errorchecking

# Constants used on serverside
FAIL        = 0
SUCCESS        = 1
WAIT        = 2
REQUEST_KEY    = 3

def sendsignedchallenge(conn, unit_id, fp_pkey, challenge):
    fh_pkey = open(fp_pkey,'r')
    pkey_data=fh_pkey.read()
    fh_pkey.close()
    pkey = crypto.load_privatekey(crypto.FILETYPE_PEM, pkey_data )

    signature = crypto.sign(pkey, str.encode( challenge ), "sha1")

    data = {}
    data["unit_id"] = unit_id
    data["signature"] = bytes.decode( b64encode( signature ) )

    post = {}
    post["data"] = json.dumps( data )

    params = urllib.parse.urlencode( post, doseq=True )
    headers = {"Content-type": "application/x-www-form-urlencoded"}

    path = urllib.parse.quote(AUTH_PATH + AUTH_FILE)

    conn.request("POST", path, params, headers)

    r = conn.getresponse()
    data = r.read()

    sys_status = {}
    sys_status['Code'] = r.status
    if r.status not in ( 200, 403):
        #print("Wrong status %d"%r.status)
        sys_status['status'] = False
        return sys_status

    rp = json.loads( data.decode('utf-8') )


    if r.status == 200:
        if "token" not in rp:
            #print("Unexpected server response, no token %s" % rp)
            sys_status['status'] = False
            sys_status['message']="Access Denied, no token received"
            sys_status['Code'] = "500"  # return a server error, since we can not understand the answer

            return False
        else:
            sys_status['bytes_used'] = rp['bytes_used']
            sys_status['quota'] = rp['quota']
            sys_status['enddate'] = rp['enddate']
            sys_status['quota'] = str(1024*1024*1024*int(sys_status['quota'][:-2]))


    if r.status == 403:
        #print("Access denied")
        sys_status['status'] = False
        sys_status['message']="Access Denied"
        return sys_status

    return sys_status;


def getchallenge(conn, unit_id):

    qs = urllib.parse.urlencode({'unit_id':unit_id}, doseq=True)
    path = urllib.parse.quote(AUTH_PATH + AUTH_FILE) + "?"+qs

    conn.request( "GET", path)

    r = conn.getresponse()
    data = r.read()

    if r.status != 200:
        sys_status['status'] = False
        sys_status['message']="Access Denied, no challenge received"
        sys_status['Code'] = r.status
        return sys_status

    rp = json.loads( data.decode('utf-8') )

    if "challange" not in rp:
        sys_status['status'] = False
        sys_status['message']="Access Denied, no challenge received"
        sys_status['Code'] = 500
        return sys_status

    return rp


def authenticate( conn, unit_id, fp_pkey ):

    challenge_response = getchallenge( conn, unit_id )

    if 'challange' not in challenge_response:
        # we got a response but it did not contain what was expected, send it on...
        print("No challage")
        return challenge_response

    response = sendsignedchallenge(conn, unit_id, fp_pkey, challenge_response['challange'])

    if not response:
        sys_status['status'] = False
        sys_status['message']="No response to signed challenge"
        sys_status['Code'] = 500
        return sys_status

    return response

def add_section_header(properties_file, header_name):
    # configparser.ConfigParser requires at least one section header in a properties file.
    # Our properties file doesn't have one, so add a header to it on the fly.
    yield '[{}]\n'.format(header_name)
    for line in properties_file:
        yield line



### -------------- MAIN ---------------
if __name__=='__main__':

    parser = argparse.ArgumentParser()
    parser.add_argument("-t", "--type", default="json", help="Output format type"
                    "Valid options are json and sh, defaults to json")
    args = parser.parse_args()

    try:
        fh_sysconf = open(SYSINFO, encoding="utf_8")
    except Exception as e:
        print("Error opening SYSINFO file: "+SYSINFO)
        print(e)
        sys.exit(1)

    sysconf = configparser.ConfigParser()
    # There are no sections in our ini files, so add one on the fly.
    try:
        sysconf.read_file(add_section_header(fh_sysconf, 'sysinfo'), source=SYSINFO)
        if 'sysinfo' not in sysconf:
            print("Missing parameters in sysinfo")
            sys.exit(1)
        sysinfo = sysconf['sysinfo']
        if 'unit_id' not in sysinfo:
            print("Missing parameters in sysinfo")
            sys.exit(1)
        unit_id = sysinfo['unit_id'].strip('"')
        if 'ca_path' not in sysinfo:
            print("Missing parameters in sysinfo")
            sys.exit(1)
        cafile = sysinfo['ca_path'].strip('"')
        if 'sys_key' not in sysinfo:
            print("Missing parameters in sysinfo")
            sys.exit(1)
        fp_pkey = sysinfo['sys_key'].strip('"')

    except Exception as e:
        print("Error parsing sysconfig")
        print(e)
        sys.exit(1)


    try:
        fh_targetconf = open(BACKUP_TARGET, encoding="utf_8")
    except Exception as e:
        print("Error opening Target file: "+BACKUP_TARGET)
        print(e)
        sys.exit(1)

    target_conf = configparser.ConfigParser()
    try:
        target_conf.read_file(add_section_header(fh_targetconf, 'target'), source=BACKUP_TARGET)
        if 'target' not in target_conf:
            print("Missing parameters in Target file")
            sys.exit(1)
        target = target_conf['target']
        if 'backend' not in target:
            print("Missing backend in target file")
            sys.exit(1)
        backend = target['backend'].strip('"')

    except Exception as e:
        print("Error parsing target file")
        print(e)
        sys.exit(1)

    if (backend == "s3op://") or (backend == "none"):
        #report server quota even if service is not active.
        try:
            import ssl
            import http.client

            ctx = ssl.SSLContext(ssl.PROTOCOL_SSLv23)

            ctx.options |= ssl.OP_NO_SSLv2
            ctx.verify_mode = ssl.CERT_REQUIRED

            try:
                ctx.load_verify_locations( cafile )
            except Exception as e:
                print("CA file error")
                print(e)
                sys.exit(1)

            conn = http.client.HTTPSConnection(AUTH_SERVER, 443, context=ctx)

            response = authenticate(conn, unit_id, fp_pkey)
        except http.client.HTTPException as e:
            print(e)

    elif backend == "local://":
        try:
            fh_backupconf = open(BACKUP_CONF, encoding="utf_8")
        except Exception as e:
            print("Error opening Target file: "+BACKUP_CONF)
            print(e)
            sys.exit(1)

        backup_conf = configparser.ConfigParser()
        try:
            backup_conf.read_file(add_section_header(fh_backupconf, 'section_backup'), source=BACKUP_TARGET)
            if 'section_backup' not in backup_conf:
                print("Missing parameters in backup config file")
                sys.exit(1)
            backup = backup_conf['section_backup']
            if 'backupdisk' not in backup:
                print("Missing backupdisk in backup config file")
                sys.exit(1)
            backupdisk = backup['backupdisk'].strip('"')
        except Exception as e:
            print("Error parsing backup config file")
            print(e)
            sys.exit(1)

        #Try to mount the disk
        try:
            FNULL = open(os.devnull, 'w')
            retcode = subprocess.call(MOUNT_SCRIPT, stdout=FNULL, stderr=subprocess.STDOUT)
            #subprocess.call([MOUNT_SCRIPT])
        except Exception as e:
            print("Error mounting disk")
            print(e)
            sys.exit(1)

        df = subprocess.Popen(["df", "/mnt/usb"], stdout=subprocess.PIPE)
        output = df.communicate()[0].decode()
        device, size, used, available, percent, mountpoint = \
        output.split("\n")[1].split()
        response = {}
        response['quota'] = int(size) * 1024
        response['bytes_used'] = int(used) * 1024

    else:
        print("Unknown backend, exit")
        sys.exit(1)


    if args.type == "sh":
        #print("Output shell format")
        for x in response.keys():
            print("%s=%s" % (x,response[x]) )
    else:
        # default print json
        #print(response)
        print(json.dumps(response))



