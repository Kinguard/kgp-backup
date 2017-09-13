import urllib.parse
import json
from base64 import b64encode
import hashlib
from OpenSSL import crypto
import configparser
import http.client
import ssl

AUTH_SERVER		= "auth.openproducts.com"
AUTH_PATH		= "/"
AUTH_FILE		= "auth.php"
REG_KEY_FILE    = "register_public.php"
SYSINFO			= "/etc/opi/sysinfo.conf"
#TODO: more errorchecking

# Constants used on serverside
FAIL		= 0
SUCCESS		= 1
WAIT		= 2
REQUEST_KEY	= 3

def get_auth_server():
	return AUTH_SERVER

def add_section_header(properties_file, header_name):
	# configparser.ConfigParser requires at least one section header in a properties file.
	# Our properties file doesn't have one, so add a header to it on the fly.
	yield '[{}]\n'.format(header_name)
	for line in properties_file:
		yield line

def get_sysinfo():
	try:
		fh_sysconf = open(SYSINFO, encoding="utf_8")
	except Exception as e:
		print("Error opening SYSINFO file: "+SYSINFO)
		print(e)
		return False

	sysconf = configparser.ConfigParser()
	# There are no sections in our ini files, so add one on the fly.
	try:
		sysconf.read_file(add_section_header(fh_sysconf, 'sysinfo'), source=SYSINFO)
		if 'sysinfo' not in sysconf:
			print("Missing parameters in sysinfo")
			return False
		sysinfo = sysconf['sysinfo']
		if 'unit_id' not in sysinfo:
			print("Missing parameters in sysinfo")
			return False
		if 'ca_path' not in sysinfo:
			print("Missing parameters in sysinfo")
			return False
		if 'sys_key' not in sysinfo:
			print("Missing parameters in sysinfo")
			return False

	except Exception as e:
		print("Error parsing sysconfig")
		print(e)
		return False

	for key in sysinfo:
		sysinfo[key] = sysinfo[key].strip('"')

	return sysinfo

def sendsignedchallenge(conn, sysinfo, challenge):
	fh_pkey = open(sysinfo['sys_key'],'r')
	pkey_data=fh_pkey.read()
	fh_pkey.close()
	pkey = crypto.load_privatekey(crypto.FILETYPE_PEM, pkey_data )
	signature = crypto.sign(pkey, str.encode( challenge ), "sha1")

	data = {}
	data["unit_id"] = sysinfo['unit_id']
	data["signature"] = bytes.decode( b64encode( signature ) )

	post = {}
	post["data"] = json.dumps( data )
	params = urllib.parse.urlencode( post, doseq=True )
	headers = {"Content-type": "application/x-www-form-urlencoded"}

	path = urllib.parse.quote(AUTH_PATH + AUTH_FILE)

	conn.request("POST", path, params, headers)

	r = conn.getresponse()
	data = r.read()
	if r.status not in ( 200, 403):
		print("Wrong status %d"%r.status)
		return False

	try:
		rp = json.loads( data.decode('utf-8') )

	except Exception as e:
		print("Error decoding json")
		print(e)
		return False


	token = ""
	if r.status == 200:
		if "token" not in rp:
			print("Unexpected server response, no token %s" % rp)
			return False
		else:
			token = rp["token"]

	if r.status == 403:
		print("Access denied")
		return False

	return token

def getchallenge(conn, unit_id):

	qs = urllib.parse.urlencode({'unit_id':unit_id}, doseq=True)
	path = urllib.parse.quote(AUTH_PATH + AUTH_FILE) + "?"+qs

	conn.request( "GET", path)

	r = conn.getresponse()
	data = r.read()

	if r.status != 200:
		print("Unable to parse server response")
		return False

	rp = json.loads( data.decode('utf-8') )

	if "challange" not in rp:
		print("Unable to parse server response, no challange %s", rp)
		return False

	return rp["challange"]


def AuthLogin():

    sysinfo = get_sysinfo()
    if not sysinfo:
        print("Error or missing information in sysinfo.conf")
        return False

    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_SSLv23)
        ctx.options |= ssl.OP_NO_SSLv2
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations( sysinfo['ca_path'] )
        conn = http.client.HTTPSConnection(get_auth_server(), 443, context=ctx)

        challenge = getchallenge( conn, sysinfo['unit_id'] )

        if not challenge:
            print("Failed to get challenge")
            raise RuntimeError('Unable to get server challange')
            return False
        else:
            token = sendsignedchallenge(conn, sysinfo, challenge)

        if not token:
            print("Failed to get token")
            raise RuntimeError('Unable to get server challange')
            return False

        #print("Authenticated, got token from auth-server.")
        return token

    except http.client.HTTPException as e:
        print(e)


