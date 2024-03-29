#!/usr/bin/python -tt

import sys, re
import atexit
sys.path.append("@FENCEAGENTSLIBDIR@")
from fencing import *

#BEGIN_VERSION_GENERATION
RELEASE_VERSION=""
REDHAT_COPYRIGHT=""
BUILD_DATE=""
#END_VERSION_GENERATION

def get_power_status(conn, options):
	conn.send("2")
	conn.log_expect(options, options["--command-prompt"], int(options["--shell-timeout"]))
	status = re.compile(r"Power Status[\s]*: (on|off)", re.IGNORECASE).search(conn.before).group(1)
	conn.send("0")
	conn.log_expect(options, options["--command-prompt"], int(options["--shell-timeout"]))

	return status.lower().strip()

def set_power_status(conn, options):
	action = {
		'on' : "4",
		'off': "1"
	}[options["--action"]]

	conn.send("2")
	conn.log_expect(options, options["--command-prompt"], int(options["--shell-timeout"]))
	conn.send_eol(action)
	conn.log_expect(options, ["want to power off", "'yes' or 'no'"], int(options["--shell-timeout"]))
	conn.send_eol("yes")
	conn.log_expect(options, "any key to continue", int(options["--power-timeout"]))
	conn.send_eol("")
	conn.log_expect(options, options["--command-prompt"], int(options["--shell-timeout"]))
	conn.send_eol("0")
	conn.log_expect(options, options["--command-prompt"], int(options["--shell-timeout"]))

def main():
	device_opt = [ "ipaddr", "login", "passwd", "secure", "cmd_prompt" ]

	atexit.register(atexit_handler)

	all_opt["cmd_prompt"]["default"] = [ "to quit:" ]

	opt = process_input(device_opt)

	# set default port for telnet only
	if 0 == opt.has_key("--ssh") and 0 == opt.has_key("--ipport"):
		opt["--ipport"] = "3172"

	options = check_input(device_opt, opt)

	docs = { }
	docs["shortdesc"] = "I/O Fencing agent for Fujitsu-Siemens RSB"
	docs["longdesc"] = "fence_rsb is an I/O Fencing agent \
which can be used with the Fujitsu-Siemens RSB management interface. It logs \
into device via telnet/ssh  and reboots a specified outlet. Lengthy telnet/ssh \
connections should be avoided while a GFS cluster is running because the connection \
will block any necessary fencing actions."
	docs["vendorurl"] = "http://www.fujitsu.com"
	show_docs(options, docs)

	##
	## Operate the fencing device
	####
	conn = fence_login(options)
	result = fence_action(conn, options, set_power_status, get_power_status, None)
	fence_logout(conn, "0")
	sys.exit(result)

if __name__ == "__main__":
	main()
