#!/usr/bin/python

"""
Connect to dli-pc8000 remote management module via http and perform power
management operations.
"""

import base64
import sys
import urllib2

sys.path.append("/usr/share/fence")
from fencing import *

def http_get_file(server, credentials, filename):
    """
    Authenticate to server and gets file

    @param string server server IP address
    @param string credentials base64 built string with username and password
    @param string filename name of the file to be read
    @return tuple http status code and content/error reason
    """

    request = urllib2.Request("http://" + server + filename)
    request.add_header("Authorization", "Basic %s" % credentials)

    try:
        response = urllib2.urlopen(request)
        content = response.read()
        return response.code, content.strip()
    except urllib2.HTTPError, e:
        return e.code, e.reason
    except urllib2.URLError, e:
        return -1, e.reason


def check_status(program, ip, credentials, port):
    """
    Verify if port is up and checks the url format

    @param string program program name
    @param string ip server IP address
    @param string credentials base64 built string with username and password
    @param string port Port number to be tested/changed
    @return tuple status of the port and url format
    """

    http_code, response_body = http_get_file(ip, credentials, '/')

    if http_code != 200:
        print "Error trying to access %s. Error is: '%s'" % (ip, response_body)
        return "INVALID", None

    # outlet control page not found: get the new one and try again
    if not response_body or "URL=/" in response_body:
        prefix = "URL="
        sufix = "\">"
        start = response_body.index(prefix) + len(prefix)
        end = response_body.index(sufix, start)
        url = response_body[start:end]
        http_code, response_body = http_get_file(ip, credentials, url)

        # outlet control page still not found: unable to proceed
        if not response_body:
            print "%s: unable to retrieve HTTP root from %s\n" % (program, ip)
            return "INVALID", None

    # check both new and old url formats
    new_string = "outlet?%s=" % port
    old_string_on = "outletoff%s=" % port
    old_string_off = "outleton%s=" % port

    # test if port is present and url format
    if new_string in response_body:
        prefix = new_string
        link_type = "new"
    elif old_string_on in response_body:
        prefix = old_string_on
        link_type = "old"
    elif old_string_off in response_body:
        prefix = old_string_off
        link_type = "old"
    else:
        return "INVALID", None

    # get status if port if valid
    sufix = ">Switch"
    start = response_body.index(prefix) + len(prefix)
    end = response_body.index(sufix, start)
    control_table = response_body[start:end]

    # found string "Switch ON": status is OFF
    if "ON" in control_table:
        status = "OFF"
    # found string "Switch OFF": status is ON
    elif "OFF" in control_table:
        status = "ON"
    # found something else: status is INVALID
    else:
        status = "INVALID"

    return status, link_type


def get_commands_urls(program, port, link_type):
    """
    Build available command urls

    @param string program program name
    @param string port port number
    @param string link_type if link_type is old or new
    @return triple composed strings off_cmd, on_cmd, cycle_cmd
    """

    # compose the power management commands urls
    if link_type == "old":
        off_cmd = "/outletoff?%s" % port
        on_cmd = "/outleton?%s" % port
        cycle_cmd = "/outletccl?%s" % port
    else:
        off_cmd = "/outlet?%s=OFF" % port
        on_cmd = "/outlet?%s=ON" % port
        cycle_cmd = "/outlet?%s=CCL" % port

    return off_cmd, on_cmd, cycle_cmd


def do_action(program, ip, port, on_cmd, off_cmd, cycle_cmd, is_on, action):
    """
    Perform power command on system

    @param string program program name
    @param string ip server IP address
    @param string port port number
    @param string on_cmd command to power system on
    @param string off_cmd command to power system off
    @param string cycle_cmd command to power system off and on again
    @param string status if system is ON or OFF
    @param string action action to be performed
    """

    # action is not recognized
    if action not in ("on", "off", "reboot"):
        print "%s: %s:%s: Invalid action '%s'\n" % (program, ip, port, action)
        return

    # system is off, requested action is turning it off
    if not is_on and action == "off":
        return

    # system is on, requested action is turning it on
    if is_on and action == "on":
        return

    # system is on, requested action is turning it off
    if is_on and action == "off":
        print "%s: %s:%s: outlet ON, switching OFF ... %s\n" \
        % (program, ip, port, off_cmd)
        status = http_get_file(ip, credentials, off_cmd)

    # system is off, requested action is turning it on
    if not is_on and action == "on":
        print "%s: %s:%s: switching ON ... %s\n" % (program, ip, port, on_cmd)
        status = http_get_file(ip, credentials, on_cmd)

    # requested action is restarting it
    if action == "reboot":
        # Port is on, switch it off and on
        if is_on:
            print "%s: %s:%s: switching OFF and then ON ... %s\n" \
            % (program, ip, port, cycle_cmd)
            status = http_get_file(ip, credentials, cycle_cmd)
        # Port is off, switch it on
        else:
            message_header = "%s: %s:%s:" % (program, ip, port)
            print "%s switching ON... %s\n" % (message_header, cycle_cmd)
            status = http_get_file(ip, credentials, on_cmd)

    print "%s: %s:%s: action '%s' complete\n" % (program, ip, port, action)


def usage(program):
    """
    Displays usage

    @param string program program name
    """

    message_header = "Usage: %s <ip> <port> <username> <password>" % program
    action = "<action: on|off|reboot>"
    print "%s %s \n" % (message_header, action)


# program name
program = sys.argv[0]

device_opt = [ "ipaddr", "login", "passwd", "ipport" ]
options = check_input(device_opt, process_input(device_opt))

action = options['--action']
login = options['--username']
passwd = options['--password']
ipaddr = options['--ip']
port = options['--ipport']

# build the authentication string
credentials = base64.encodestring('%s:%s' % (login, passwd)).strip()

print "%s: %s:%s: checking port status\n" % (program, ipaddr, port)

# get the status of the port and link_type
port_status, link_type = check_status(program, ipaddr, credentials, port)

# port is not found: exit dli-pc8000
if port_status == "INVALID":
    print "%s: %s: port not found." % (program, port)
    sys.exit(1)

if action == "status":
    print "System status is %s" % (port_status)
    sys.exit(1)

message_header = "%s: %s:%s:" % (program, ipaddr, port)
print "%s port found, attempting action '%s'\n" % (message_header, action)

# get urls of available commands
off_cmd, on_cmd, cycle_cmd = get_commands_urls(program, port, link_type)

is_system_on = True if port_status == "ON" else False

# switch port on/off
do_action(program, ipaddr, port, on_cmd, off_cmd, cycle_cmd, is_system_on, action)
