/*
 * fence_zvm.c: SMAPI interface for managing zVM Guests
 *
 * Copyright (C) 2012 Sine Nomine Associates
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * Authors:
 * Neale Ferguson <neale@sinenomine.net>
 *
 */

#ifdef __s390__
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netiucv/iucv.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <getopt.h>
#include <ctype.h>
#include <syslog.h>
#include "fence_zvm.h"

#define MIN(a,b)	((a) < (b) ? (a) : (b))
#define DEFAULT_TIMEOUT 300

static int zvm_smapi_reportError(void *, void *);

static struct option longopts[] = {
	{"action",	required_argument,	NULL, 'o'},
	{"help",	no_argument,		NULL, 'h'},
	{"ip",		required_argument,	NULL, 'a'},
	{"plug",	required_argument,	NULL, 'n'},
	{"timeout",	required_argument,	NULL, 'T'},
	{NULL,		0,			NULL, 0}
};

static char *optString = "a:ho:n:T:";

static int zvm_metadata(void);
static int usage(void);

/**
 * zvm_smapi_open:
 * @zvm: z/VM driver information
 *
 * Opens a connection with the z/VM SMAPI server
 */
int
zvm_smapi_open(zvm_driver_t *zvm)
{
	int rc = -1,
	sockaddrlen;
	static char iucvprog[9] = "DMSRSRQU\0";
	struct sockaddr_iucv siucv_addr;
	const struct sockaddr *siucv_ptr = (void *) &siucv_addr;

	if ((zvm->sd = socket(AF_IUCV, SOCK_STREAM, IPPROTO_IP)) != -1) {
		memset(&siucv_addr,0,sizeof(siucv_addr));
		siucv_addr.siucv_family = AF_IUCV;
		siucv_addr.siucv_port = 0;
		siucv_addr.siucv_addr = 0;
		memset(&siucv_addr.siucv_nodeid,' ',8);
		memset(&siucv_addr.siucv_user_id,' ',8);
		memset(&siucv_addr.siucv_name,' ',8);
		sockaddrlen = sizeof(siucv_addr);
		if ((rc = bind(zvm->sd,siucv_ptr,sockaddrlen)) != -1) {
			memcpy(&siucv_addr.siucv_user_id,zvm->smapiSrv,strlen(zvm->smapiSrv));
			memcpy(&siucv_addr.siucv_name,&iucvprog,8);
			rc = connect(zvm->sd,(__CONST_SOCKADDR_ARG)siucv_ptr,sockaddrlen);
		}
		if (rc == -1) {
			syslog(LOG_ERR, "Error connecting to %s - %m", zvm->smapiSrv);
			close(zvm->sd);
		}
	}
	return(rc);
}

/**
 * zvm_smapi_imageRecycle
 * @zvm: z/VM driver information
 *
 * Deactivates a virtual image
 */
int
zvm_smapi_imageRecycle(zvm_driver_t *zvm)
{
	struct _inPlist {
		int32_t	lPlist;
		int32_t	lFName;
		char	fName[13];
		int32_t lUser;
		int32_t lPass;
		int32_t	lTarget;
		char	target[0];
	} __attribute__ ((__packed__)) *inPlist;
	int32_t	lInPlist;
	struct	_outPlist {
		smapiOutHeader_t hdr;
		int32_t	nActive;
		int32_t	nInActive;
		int32_t	lFail;
		char	failArray[0];
	} *outPlist = NULL;
	void	*pOut = NULL;
	int32_t	lRsp;
	uint32_t reqId;
	int	rc;

	lInPlist = sizeof(*inPlist) + strlen(zvm->target);
	inPlist = malloc(lInPlist);
	if (inPlist != NULL) {
		inPlist->lPlist = lInPlist - sizeof(inPlist->lPlist);
		inPlist->lFName = sizeof(inPlist->fName);
		memcpy(inPlist->fName, Image_Recycle, sizeof(inPlist->fName));
		inPlist->lUser = inPlist->lPass = 0;
		inPlist->lTarget = strlen(zvm->target);
		memcpy(inPlist->target, zvm->target, inPlist->lTarget);
		if ((rc = zvm_smapi_send(zvm, inPlist, &reqId, lInPlist)) != -1) {
			if ((rc = zvm_smapi_recv(zvm, &pOut, &lRsp)) != -1) {
				outPlist = pOut;
				if (outPlist->hdr.rc == 0) {
					syslog(LOG_INFO, "Recycling of %s successful",
					       zvm->target);
					rc = 0;
				} else {
					if ((outPlist->hdr.rc == RCERR_IMAGEOP) &
					    ((outPlist->hdr.reason == RS_NOT_ACTIVE) |
					     (outPlist->hdr.reason == RS_BEING_DEACT))) {
						syslog(LOG_INFO, "Recycling of %s successful",
						       zvm->target);
						rc = 0;
					} else {
						rc = outPlist->hdr.rc;
						zvm->reason = outPlist->hdr.reason;
						(void) zvm_smapi_reportError(inPlist, outPlist);
					}
				}
			}
		}
		free(inPlist);
		free(outPlist);
	} else {
		syslog(LOG_ERR, "%s - cannot allocate parameter list", __func__);
		rc = -1;
	}
	return(rc);
}

/**
 * zvm_smapi_send:
 * @zvm: z/VM driver information
 * @reqid: Returned request id
 * @req: Request parameter list
 * @lSend: Length of request
 *
 * Send a request to the SMAPI server and retrieve the request id
 */
int
zvm_smapi_send(zvm_driver_t *zvm, void *req, uint32_t *reqId, int32_t lSend)
{
	int	rc,
		nFds;
	fd_set	readFds;
	struct timeval timeout;

	timeout.tv_sec = 30;
	timeout.tv_usec = 0;
	zvm->reason = -1;
	if ((rc = zvm_smapi_open(zvm)) == 0) {
		rc = send(zvm->sd,req,lSend,0);
		if (rc != -1) {
			FD_ZERO(&readFds);
			FD_SET(zvm->sd,&readFds);
			nFds = zvm->sd + 1; 

			if ((rc = select(nFds,&readFds,NULL,NULL,&timeout)) != -1) {
				/*
				 * Get request ID
				 */ 
				rc = recv(zvm->sd,reqId,sizeof(*reqId),0);
				if (rc == -1)
					syslog(LOG_ERR, "Error receiving from SMAPI - %m");
			}
		} else 
			syslog(LOG_ERR, "Error sending to SMAPI - %m");
	}
	return(rc);
}

/**
 * zvm_smapi_recv:
 * @zvm: z/VM driver information
 * @req: Returned response parameter list
 * @lRsp: Length of response
 *
 * Receive a response from the SMAPI server
 */
int
zvm_smapi_recv(zvm_driver_t *zvm, void **rsp, int32_t *lRsp)
{
	int	rc,
		lRem = 0,
		nFds;
	void	*pRecv = rsp;
	fd_set	readFds;
	smapiOutHeader_t *out;
	struct timeval timeout;

	timeout.tv_sec = 30;
	timeout.tv_usec = 0;
	FD_ZERO(&readFds);
	FD_SET(zvm->sd,&readFds);
	nFds = zvm->sd + 1; 

	zvm->reason = -1;
	if ((rc = select(nFds,&readFds,NULL,NULL,&timeout)) != -1) {
	/*
	 * Get response length
	 */ 
	if ((rc = recv(zvm->sd,lRsp,sizeof(*lRsp),0)) != -1) {
		lRem  = *lRsp;
		if (*rsp == NULL) 
			*rsp = malloc(*lRsp + sizeof(out->outLen));
		out = *rsp;
		out->outLen = *lRsp;
		pRecv = &out->reqId;
		while (lRem > 0) {
			if ((rc = recv(zvm->sd,pRecv,lRem,0)) != -1) {
				lRem -= rc;
				pRecv = (void *) ((uintptr_t) pRecv + rc);
			} else 
				syslog(LOG_ERR, "Error receiving from SMAPI - %m");
				(void) zvm_smapi_close(zvm);
				return(rc);
			}
			zvm->reason = out->reason;
		}
	} else 
		syslog(LOG_ERR, "Error receiving from SMAPI - %m");

	(void) zvm_smapi_close(zvm);

	return(rc);
}

/**
 * zvm_smapi_close:
 * @zvm: z/VM driver information
 *
 * Close a connection with the z/VM SMAPI server
 */
int
zvm_smapi_close(zvm_driver_t *zvm)
{
	close(zvm->sd);
	return(0);
}

/**
 * zvm_smapi_reportError
 * @inHdr - Input parameter list header
 * @outHdr - Output parameter list header
 *
 * Report an error from the SMAPI server
 */
static int
zvm_smapi_reportError(void *inHdr, void *oHdr)
{
	struct _inParm {
		int32_t	lPlist;
		int32_t	lFName;
		char	fName[0];
	} *inParm = inHdr;
	smapiOutHeader_t *outHdr = oHdr;
	char	fName[64];

	memset(fName, 0, sizeof(fName));
	memcpy(fName, inParm->fName, inParm->lFName);
	syslog(LOG_ERR, "%s - returned (%d,%d)", 
		fName, outHdr->rc, outHdr->reason);
	return(-1);
}


/**
 * trim - Trim spaces from string
 * @str - Pointer to string
 *
 */
static int
trim(char *str)
{
	char *p;
	int len;

	if (!str) 
		return (0);

	len = strlen (str);

	while (len--) {
		if (isspace (str[len])) {
			str[len] = 0;
		} else {
			break;
		}
	}

	for (p = str; *p && isspace (*p); p++);

	memmove(str, p, strlen (p) + 1);

	return (strlen (str));
}

/**
 * zvm_metadata - Show fence metadata 
 * @self - Path to this executable
 *
 */
static int
zvm_metadata()
{
	fprintf (stdout, "<?xml version=\"1.0\" ?>\n");
	fprintf (stdout, "<resource-agent name=\"fence_zvm\"");
	fprintf (stdout, " shortdesc=\"Fence agent for use with z/VM Virtual Machines\">\n");
	fprintf (stdout, "<longdesc>");
	fprintf (stdout, "The fence_zvm agent is intended to be used with with z/VM SMAPI service.");
	fprintf (stdout, "</longdesc>\n");

	fprintf (stdout, "<parameters>\n");

	fprintf (stdout, "\t<parameter name=\"port\" unique=\"1\" required=\"1\">\n");
	fprintf (stdout, "\t\t<getopt mixed=\"-n, --plug\" />\n");
	fprintf (stdout, "\t\t<content type=\"string\" />\n");
	fprintf (stdout, "\t\t<shortdesc lang=\"en\">%s</shortdesc>\n",
	     "Name of the Virtual Machine to be fenced");
	fprintf (stdout, "\t</parameter>\n");

	fprintf (stdout, "\t<parameter name=\"ipaddr\" unique=\"1\" required=\"1\">\n");
	fprintf (stdout, "\t\t<getopt mixed=\"-a, --ip\" />\n");
	fprintf (stdout, "\t\t<content type=\"string\" />\n");
	fprintf (stdout, "\t\t<shortdesc lang=\"en\">%s</shortdesc>\n",
	     "Name of the SMAPI IUCV Server Virtual Machine");
	fprintf (stdout, "\t</parameter>\n");

	fprintf (stdout, "\t<parameter name=\"action\" unique=\"1\" required=\"0\">\n");
	fprintf (stdout, "\t\t<getopt mixed=\"-o, --action\" />\n");
	fprintf (stdout, "\t\t<content type=\"string\" default=\"off\" />\n");
	fprintf (stdout, "\t\t<shortdesc lang=\"en\">%s</shortdesc>\n",
	     "Fencing action");
	fprintf (stdout, "\t</parameter>\n");

	fprintf (stdout, "\t<parameter name=\"usage\" unique=\"1\" required=\"0\">\n");
	fprintf (stdout, "\t\t<getopt mixed=\"-h, --help\" />\n");
	fprintf (stdout, "\t\t<content type=\"boolean\" />\n");
	fprintf (stdout, "\t\t<shortdesc lang=\"en\">%s</shortdesc>\n",
	     "Print usage");
	fprintf (stdout, "\t</parameter>\n");

	fprintf (stdout, "</parameters>\n");

	fprintf (stdout, "<actions>\n");
	fprintf (stdout, "\t<action name=\"off\" />\n");
	fprintf (stdout, "\t<action name=\"metadata\" />\n");
	fprintf (stdout, "</actions>\n");

	fprintf (stdout, "</resource-agent>\n");

	return(0);

}

/**
 * get_options_stdin - get options from stdin
 * @zvm - Pointer to driver information
 *
 */
static int
get_options_stdin (zvm_driver_t *zvm)
{
	char	buf[1024],
		*endPtr,
		*opt,
		*arg;
	int32_t lSrvName,
		lTarget;
	int	fence = 0;

	while (fgets (buf, sizeof (buf), stdin) != 0) {
		if (trim(buf) == 0) {
			continue;
		}
		if (buf[0] == '#') {
			continue;
		}

		opt = buf;

		if ((arg = strchr(opt, '=')) != 0) {
			*arg = 0;
			arg++;
		} else {
			continue;
		}

		if (trim(arg) == 0)
			continue;

		if (!strcasecmp (opt, "action")) {
			if (strcasecmp(arg, "off") == 0) {
				fence = 0;
			} else if (strcasecmp(arg, "metadata") == 0) {
				fence = 1;
			} else {
				fence = 2;
			}
		} else if (!strcasecmp (opt, "ipaddr")) {
			lSrvName = MIN(strlen(arg), sizeof(zvm->smapiSrv));
			memcpy(zvm->smapiSrv, arg, lSrvName);
			continue;
		} else if (!strcasecmp (opt, "port")) {
			lTarget = MIN(strlen(arg), sizeof(zvm->target)-1);
			strncpy(zvm->target, arg, lTarget);
			continue;
		} else if (!strcasecmp (opt, "timeout")) {
			zvm->timeOut = strtoul(arg, &endPtr, 10);
			if (*endPtr != 0) {
				syslog(LOG_WARNING, "Invalid timeout value specified %s "
				       "defaulting to %d", 
				       arg, DEFAULT_TIMEOUT);
				zvm->timeOut = DEFAULT_TIMEOUT;
			}
		} else if (!strcasecmp (opt, "help")) {
			fence = 2;
		}
	}
	return(fence);
}

/**
 * get_options - get options from the command line
 * @argc - Count of arguments
 * @argv - Array of character strings
 * @zvm - Pointer to driver information
 *
 */
static int
get_options(int argc, char **argv, zvm_driver_t *zvm)
{
	int	c,
		fence = 0;
	int32_t	lSrvName,
		lTarget;
	char	*endPtr;

	while ((c = getopt_long(argc, argv, optString, longopts, NULL)) != -1) {
		switch (c) {
		case 'n' :
			lTarget = MIN(strlen(optarg), sizeof(zvm->target));
			memcpy(zvm->target, optarg, lTarget);
			break;
		case 'o' :
			if (strcasecmp(optarg, "off") == 0) {
				fence = 0;
			} else if (strcasecmp(optarg, "metadata") == 0) {
				fence = 1;
			} else {
				fence = 2;
			}
			break;
		case 's' :
			lSrvName = MIN(strlen(optarg), sizeof(zvm->smapiSrv));
			memcpy(zvm->smapiSrv, optarg, lSrvName);
			break;
		case 't' :
			zvm->timeOut = strtoul(optarg, &endPtr, 10);
			if (*endPtr != 0) {
				syslog(LOG_WARNING, "Invalid timeout value specified: %s - "
				       "defaulting to %d", 
				       optarg, DEFAULT_TIMEOUT);
				zvm->timeOut = DEFAULT_TIMEOUT;
			}
			break;
		default :
			fence = 2;
		}
	}
	return(fence);
}

/**
 * usage - display command syntax and parameters
 *
 */
static int
usage()
{
	fprintf(stderr,"Usage: fence_zvm [options]\n\n"
		"\tWhere [options] =\n"
		"\t-o --action [action]    - \"off\", \"metadata\"\n"
		"\t-n --plug [target]      - Name of virtual machine to fence\n"
		"\t-s --server [server]    - Name of SMAPI IUCV Request server\n"
		"\t-T --timeout [secs]     - Time to wait for fence in seconds - currently ignored\n"
		"\t-h --help               - Display this usage information\n");
	return(1);
}

/**
 * check_param - Check that mandatory parameters have been specified
 * @zvm - Pointer to driver information
 *
 */
static int
check_parm(zvm_driver_t *zvm) 
{
	int rc;

	if (zvm->smapiSrv[0] != 0) {
		if (zvm->target[0] != 0) {
			rc = 0;
		} else {
			syslog(LOG_ERR, "Missing fence target name");
			rc = 2;
		}	
	} else {
		syslog(LOG_ERR, "Missing SMAPI server name");
		rc = 1;
	}	
	return(rc);
}

int
main(int argc, char **argv)
{
	zvm_driver_t	zvm;
	int	fence,
		rc = 0;

	openlog ("fence_zvm", LOG_CONS|LOG_PID, LOG_DAEMON);
	memset(&zvm, 0, sizeof(zvm));
	zvm.timeOut = DEFAULT_TIMEOUT;

	if (argc > 1)
		fence = get_options(argc, argv, &zvm);
	else
		fence = get_options_stdin(&zvm);

	switch(fence) {
		case 0 :
			if ((rc = check_parm(&zvm)) == 0)
				rc = zvm_smapi_imageRecycle(&zvm);
			break;
		case 1 :
			rc = zvm_metadata();
			break;
		case 2 :
			rc = usage();
	}
	closelog();
	return (rc);
}
#else
#include <syslog.h>
int
main(int argc, char **argv)
{
	openlog ("fence_zvm", LOG_CONS|LOG_PID, LOG_DAEMON);
	syslog(LOG_ERR,"Fencing of a z/VM agent is not possible on this platform\n");
	closelog();
	return(-1);
}
#endif
