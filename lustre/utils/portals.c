/*
 * Copyright (c) 2003, 2010, Oracle and/or its affiliates. All rights reserved.
 *
 * Copyright (c) 2013, 2017, Intel Corporation.
 *
 *   This file is part of Lustre, https://wiki.whamcloud.com/
 *
 *   Portals is free software; you can redistribute it and/or
 *   modify it under the terms of version 2 of the GNU General Public
 *   License as published by the Free Software Foundation.
 *
 *   Portals is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Portals; if not, write to the Free Software
 *   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 *
 */
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#ifdef HAVE_NETDB_H
# include <netdb.h>
#endif
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <time.h>
#include <linux/types.h>

#include <libcfs/util/ioctl.h>
#include <linux/lnet/libcfs_debug.h>
#include <linux/lnet/lnet-dlc.h>
#include <linux/lnet/lnetctl.h>
#include <linux/lnet/nidstr.h>
#include <linux/lnet/socklnd.h>
#include <lnetconfig/liblnetconfig.h>
#include <lustre/lustreapi.h>
#include <lustre_ioctl_old.h>

unsigned int libcfs_debug;
unsigned int libcfs_printk = D_CANTMASK;

static bool  g_net_interactive;
static bool  g_net_set;
static __u32 g_net;

#define IOC_BUF_SIZE	8192
static char local_buf[IOC_BUF_SIZE];
static char *ioc_buf = local_buf;

/* Convert a string boolean to an int; "enable" -> 1 */
int
lnet_parse_bool (int *b, char *str)
{
	if (!strcasecmp(str, "no") ||
	    !strcasecmp(str, "n") ||
	    !strcasecmp(str, "off") ||
	    !strcasecmp(str, "down") ||
	    !strcasecmp(str, "disable")) {
		*b = 0;

		return 0;
	}

	if (!strcasecmp(str, "yes") ||
	    !strcasecmp(str, "y") ||
	    !strcasecmp(str, "on") ||
	    !strcasecmp(str, "up") ||
	    !strcasecmp(str, "enable")) {
		*b = 1;

		return 0;
	}

	return -1;
}

int
lnet_parse_port(int *port, char *str)
{
	char *end;

	*port = strtol(str, &end, 0);

	if (*end == 0 &&                        /* parsed whole string */
	    *port > 0 && *port < 65536)         /* minimal sanity check */
		return 0;

	return -1;
}

#ifdef HAVE_GETHOSTBYNAME
static struct hostent *
ptl_gethostbyname(char *hname)
{
	struct hostent *he;

	he = gethostbyname(hname);
	if (!he) {
		switch (h_errno) {
		case HOST_NOT_FOUND:
		case NO_ADDRESS:
			fprintf(stderr, "Unable to resolve hostname: %s\n",
				hname);
			break;
		default:
			fprintf(stderr, "gethostbyname error for %s: %s\n",
				hname, strerror(h_errno));
			break;
		}
		return NULL;
	}
	return he;
}
#endif

int
lnet_parse_ipquad(__u32 *ipaddrp, char *str)
{
	int a, b, c, d;

	if (sscanf(str, "%d.%d.%d.%d", &a, &b, &c, &d) == 4 &&
	    (a & ~0xff) == 0 && (b & ~0xff) == 0 &&
	    (c & ~0xff) == 0 && (d & ~0xff) == 0) {
		*ipaddrp = (a << 24) | (b << 16) | (c << 8) | d;

		return 0;
	}

	return -1;
}

int
lnet_parse_ipaddr(__u32 *ipaddrp, char *str)
{
#ifdef HAVE_GETHOSTBYNAME
	struct hostent *he;
#endif

	if (!strcmp(str, "_all_")) {
		*ipaddrp = 0;
		return 0;
	}

	if (lnet_parse_ipquad(ipaddrp, str) == 0)
		return 0;

#ifdef HAVE_GETHOSTBYNAME
	if ((('a' <= str[0] && str[0] <= 'z') ||
	     ('A' <= str[0] && str[0] <= 'Z')) &&
	      (he = ptl_gethostbyname(str)) != NULL) {
		__u32 addr = *(__u32 *)he->h_addr;

		*ipaddrp = ntohl(addr);         /* HOST byte order */
		return 0;
	}
#endif

	return -1;
}

char *
ptl_ipaddr_2_str(__u32 ipaddr, char *str, size_t strsize, int lookup)
{
#ifdef HAVE_GETHOSTBYNAME
	__u32 net_ip;
	struct hostent *he;

	if (lookup) {
		net_ip = htonl(ipaddr);
		he = gethostbyaddr(&net_ip, sizeof(net_ip), AF_INET);
		if (he) {
			snprintf(str, strsize, "%s", he->h_name);
			return str;
		}
	}
#endif

	sprintf(str, "%d.%d.%d.%d",
		(ipaddr >> 24) & 0xff, (ipaddr >> 16) & 0xff,
		(ipaddr >> 8) & 0xff, ipaddr & 0xff);
	return str;
}

int
lnet_parse_time(time_t *t, char *str)
{
	char *end;
	int n;
	struct tm tm;

	*t = strtol(str, &end, 0);
	if (*end == 0) /* parsed whole string */
		return 0;

	memset(&tm, 0, sizeof(tm));
	n = sscanf(str, "%d-%d-%d-%d:%d:%d",
		   &tm.tm_year, &tm.tm_mon, &tm.tm_mday,
		   &tm.tm_hour, &tm.tm_min, &tm.tm_sec);
	if (n != 6)
		return -1;

	tm.tm_mon--;                    /* convert to 0 == Jan */
	tm.tm_year -= 1900;             /* y2k quirk */
	tm.tm_isdst = -1;               /* dunno if it's daylight savings... */

	*t = mktime(&tm);
	if (*t == (time_t)-1)
		return -1;

	return 0;
}

int
lnet_parse_nid(char *nid_str, struct lnet_process_id *id_ptr)
{
	id_ptr->pid = LNET_PID_ANY;
	id_ptr->nid = libcfs_str2nid(nid_str);
	if (id_ptr->nid == LNET_NID_ANY) {
		fprintf(stderr, "Can't parse nid \"%s\"\n", nid_str);
		return -1;
	}

	return 0;
}

static int g_net_is_set(char *cmd)
{
	if (g_net_set)
		return 1;

	if (cmd) {
		char *net;

		if (g_net_interactive)
			net = "network";
		else
			net = "--net";

		fprintf(stderr,
			"You must run '%s <network>' command before '%s'\n",
			cmd, net);
		return 0;
	}

	return 0;
}

static int g_net_is_compatible(char *cmd, ...)
{
	va_list ap;
	int nal;

	if (!g_net_is_set(cmd))
		return 0;

	va_start(ap, cmd);

	do {
		nal = va_arg(ap, int);
		if (nal == LNET_NETTYP(g_net)) {
			va_end(ap);
			return 1;
		}
	} while (nal != 0);

	va_end(ap);

	if (cmd)
		fprintf(stderr, "Command %s not compatible with %s NAL\n",
			cmd, libcfs_lnd2str(LNET_NETTYP(g_net)));

	return 0;
}

int ptl_initialize(int argc, char **argv)
{
	if (argc > 1)
		g_net_interactive = true;

	register_ioc_dev(LNET_DEV_ID, LNET_DEV_PATH);

	return 0;
}

int jt_ptl_network(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	__u32 net = LNET_NET_ANY;
	int rc;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <net>|up|down\n", argv[0]);
		return -1;
	}

	if (!strcmp(argv[1], "unconfigure") || !strcmp(argv[1], "down")) {
		LIBCFS_IOC_INIT(data);
		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_UNCONFIGURE, &data);

		if (rc == 0) {
			printf("LNET ready to unload\n");
			return 0;
		}

		if (errno == ENODEV) {
			printf("LNET is currently not loaded.");
			return 0;
		}

		if (errno == EBUSY)
			fprintf(stderr, "LNET busy\n");
		else
			fprintf(stderr, "LNET unconfigure error %d: %s\n",
				errno, strerror(errno));
		return -1;
	} else if (!strcmp(argv[1], "configure") || !strcmp(argv[1], "up")) {
		LIBCFS_IOC_INIT(data);
		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_CONFIGURE, &data);

		if (rc == 0) {
			printf("LNET configured\n");
			return 0;
		}

		fprintf(stderr, "LNET configure error %d: %s\n",
			errno, strerror(errno));
		return -1;
	}

	net = libcfs_str2net(argv[1]);
	if (net == LNET_NET_ANY) {
		fprintf(stderr, "Can't parse net %s\n", argv[1]);
		return -1;
	}

	g_net_set = true;
	g_net = net;
	return 0;
}

#ifndef IOC_LIBCFS_GET_NI
#define IOC_LIBCFS_GET_NI	_IOWR('e', 50, IOCTL_LIBCFS_TYPE)
#endif

int
jt_ptl_list_nids(int argc, char **argv)
{
	int all = 0, return_nid = 0;
	yaml_emitter_t request;
	yaml_parser_t reply;
	yaml_event_t event;
	struct nl_sock *sk;
	bool done = false;
	int rc = 0;

	all = (argc == 2) && (strcmp(argv[1], "all") == 0);
	/* Hack to pass back value */
	return_nid = (argc == 2) && (argv[1][0] == 1);

	if ((argc > 2) && !(all || return_nid)) {
		fprintf(stderr, "usage: %s [all]\n", argv[0]);
		return 0;
	}

	sk = nl_socket_alloc();
	if (!sk)
		goto old_api;

	/* Setup parser to receive Netlink packets */
	rc = yaml_parser_initialize(&reply);
	if (rc == 0) {
		yaml_parser_log_error(&reply, stderr, NULL);
		goto old_api;
	}

	rc = yaml_parser_set_input_netlink(&reply, sk, false);
	if (rc == 0) {
		yaml_parser_log_error(&reply, stderr, NULL);
		yaml_parser_delete(&reply);
		goto old_api;
	}

	/* Create Netlink emitter to send request to kernel */
	rc = yaml_emitter_initialize(&request);
	if (rc == 0) {
		yaml_parser_log_error(&reply, stderr, NULL);
		yaml_parser_delete(&reply);
		goto old_api;
	}

	rc = yaml_emitter_set_output_netlink(&request, sk, LNET_GENL_NAME, 1,
					     LNET_CMD_NETS, NLM_F_DUMP);
	if (rc == 0) {
		yaml_emitter_log_error(&request, stderr);
		yaml_emitter_delete(&request);
		yaml_parser_delete(&reply);
		goto old_api;
	}

	yaml_emitter_open(&request);
	yaml_document_start_event_initialize(&event, NULL, NULL, NULL, 0);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_start_event_initialize(&event, NULL,
					    (yaml_char_t *)YAML_MAP_TAG,
					    1, YAML_ANY_MAPPING_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_scalar_event_initialize(&event, NULL,
				     (yaml_char_t *)YAML_STR_TAG,
				     (yaml_char_t *)"net",
				     strlen("net"), 1, 0,
				     YAML_PLAIN_SCALAR_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	/* no net_id */
	if (!g_net_set || g_net == LNET_NET_ANY) {
		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)"",
					     strlen(""), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;
	} else {
		char *net_id = libcfs_net2str(g_net);

		yaml_sequence_start_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_SEQ_TAG,
						     1, YAML_ANY_SEQUENCE_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_mapping_start_event_initialize(&event, NULL,
						    (yaml_char_t *)YAML_MAP_TAG,
						    1, YAML_ANY_MAPPING_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)"net type",
					     strlen("net type"),
					     1, 0, YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)net_id,
					     strlen(net_id), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_mapping_end_event_initialize(&event);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_sequence_end_event_initialize(&event);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;
	}
	yaml_mapping_end_event_initialize(&event);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_document_end_event_initialize(&event, 0);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	rc = yaml_emitter_close(&request);
emitter_error:
	if (rc == 0) {
		yaml_emitter_log_error(&request, stderr);
		rc = -EINVAL;
	}
	yaml_emitter_delete(&request);

	while (!done) {
		rc = yaml_parser_parse(&reply, &event);
		if (rc == 0)
			break;

		if (event.type == YAML_SCALAR_EVENT &&
		    strcmp((char *)event.data.scalar.value, "nid") == 0) {
			char *tmp;

			yaml_event_delete(&event);
			rc = yaml_parser_parse(&reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				break;
			}

			tmp = (char *)event.data.scalar.value;
			if (all || strcmp(tmp, "0@lo") != 0) {
				printf("%s\n", tmp);
				if (return_nid) {
					*(__u64 *)(argv[1]) = libcfs_str2nid(tmp);
					return_nid--;
				}
			}
		}
		done = (event.type == YAML_STREAM_END_EVENT);
		yaml_event_delete(&event);
	}

	if (rc == 0)
		yaml_parser_log_error(&reply, stderr, NULL);
	yaml_parser_delete(&reply);
old_api: {
#ifdef IOC_LIBCFS_GET_NI
	int count;

	if (sk)
		nl_socket_free(sk);
	if (rc == 1)
		return 0;

	for (count = 0;; count++) {
		struct libcfs_ioctl_data data;

		LIBCFS_IOC_INIT(data);
		data.ioc_count = count;
		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_GET_NI, &data);

		if (rc < 0) {
			if ((count > 0) && (errno == ENOENT))
				/* We found them all */
				break;
			fprintf(stderr, "IOC_LIBCFS_GET_NI error %d: %s\n",
				errno, strerror(errno));
			return -1;
		}

		if (all || (data.ioc_nid != LNET_NID_LO_0)) {
			printf("%s\n", libcfs_nid2str(data.ioc_nid));
			if (return_nid) {
				*(__u64 *)(argv[1]) = data.ioc_nid;
				return_nid--;
			}
		}
	}

#else
	rc = -1;
#endif
	}
	return rc;
}

int
jt_ptl_which_nid(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	int best_dist = 0;
	int best_order = 0;
	lnet_nid_t   best_nid = LNET_NID_ANY;
	int dist;
	int order;
	lnet_nid_t nid;
	char *nidstr;
	int rc;
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: %s NID [NID...]\n", argv[0]);
		return 0;
	}

	for (i = 1; i < argc; i++) {
		nidstr = argv[i];
		nid = libcfs_str2nid(nidstr);
		if (nid == LNET_NID_ANY) {
			fprintf(stderr, "Can't parse NID %s\n", nidstr);
			return -1;
		}

		LIBCFS_IOC_INIT(data);
		data.ioc_nid = nid;

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_LNET_DIST, &data);
		if (rc != 0) {
			fprintf(stderr, "Can't get distance to %s: %s\n",
				nidstr, strerror(errno));
			return -1;
		}

		dist = data.ioc_u32[0];
		order = data.ioc_u32[1];

		if (dist < 0) {
			if (dist == -EHOSTUNREACH)
				continue;

			fprintf(stderr, "Unexpected distance to %s: %d\n",
				nidstr, dist);
			return -1;
		}

		if (best_nid == LNET_NID_ANY ||
		    dist < best_dist ||
		    (dist == best_dist && order < best_order)) {
			best_dist = dist;
			best_order = order;
			best_nid = nid;
		}
	}

	if (best_nid == LNET_NID_ANY) {
		fprintf(stderr, "No reachable NID\n");
		return -1;
	}

	printf("%s\n", libcfs_nid2str(best_nid));
	return 0;
}

int
jt_ptl_print_interfaces(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	char buffer[3][HOST_NAME_MAX + 1];
	int index;
	int rc;

	if (!g_net_is_compatible(argv[0], SOCKLND, 0))
		return -1;

	for (index = 0; ; index++) {
		LIBCFS_IOC_INIT(data);
		data.ioc_net   = g_net;
		data.ioc_count = index;

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_GET_INTERFACE, &data);
		if (rc != 0)
			break;

		printf("%s: (%s/%s) npeer %d nroute %d\n",
		       ptl_ipaddr_2_str(data.ioc_u32[0], buffer[2],
					sizeof(buffer[2]), 1),
		       ptl_ipaddr_2_str(data.ioc_u32[0], buffer[0],
					sizeof(buffer[0]), 0),
		       ptl_ipaddr_2_str(data.ioc_u32[1], buffer[1],
					sizeof(buffer[1]), 0),
		       data.ioc_u32[2], data.ioc_u32[3]);
	}

	if (index == 0) {
		if (errno == ENOENT) {
			printf("<no interfaces>\n");
		} else {
			fprintf(stderr,
				"Error getting interfaces: %s: check dmesg.\n",
				strerror(errno));
		}
	}

	return 0;
}

int
jt_ptl_add_interface(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	__u32 ipaddr;
	int rc;
	__u32 netmask = 0xffffff00;
	int i;
	int count;
	char *end;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: %s ipaddr [netmask]\n", argv[0]);
		return 0;
	}

	if (!g_net_is_compatible(argv[0], SOCKLND, 0))
		return -1;

	if (lnet_parse_ipaddr(&ipaddr, argv[1]) != 0) {
		fprintf(stderr, "Can't parse ip: %s\n", argv[1]);
		return -1;
	}

	if (argc > 2) {
		count = strtol(argv[2], &end, 0);
		if (count > 0 && count < 32 && *end == 0) {
			netmask = 0;
			for (i = count; i > 0; i--)
				netmask = netmask | (1 << (32 - i));
		} else if (lnet_parse_ipquad(&netmask, argv[2]) != 0) {
			fprintf(stderr, "Can't parse netmask: %s\n", argv[2]);
			return -1;
		}
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net    = g_net;
	data.ioc_u32[0] = ipaddr;
	data.ioc_u32[1] = netmask;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_ADD_INTERFACE, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to add interface: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_del_interface(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	int rc;
	__u32 ipaddr = 0;

	if (argc > 2) {
		fprintf(stderr, "usage: %s [ipaddr]\n", argv[0]);
		return 0;
	}

	if (!g_net_is_compatible(argv[0], SOCKLND, 0))
		return -1;

	if (argc == 2 &&
	    lnet_parse_ipaddr(&ipaddr, argv[1]) != 0) {
		fprintf(stderr, "Can't parse ip: %s\n", argv[1]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net    = g_net;
	data.ioc_u32[0] = ipaddr;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_DEL_INTERFACE, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to delete interface: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_print_peers(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	struct lnet_process_id id;
	char buffer[2][HOST_NAME_MAX + 1];
	int index;
	int rc;

	if (!g_net_is_compatible(argv[0], SOCKLND, O2IBLND, GNILND,
				 PTL4LND, 0))
		return -1;

	for (index = 0; ; index++) {
		LIBCFS_IOC_INIT(data);
		data.ioc_net     = g_net;
		data.ioc_count   = index;

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_GET_PEER, &data);
		if (rc != 0)
			break;

		if (g_net_is_compatible(NULL, SOCKLND, 0)) {
			id.nid = data.ioc_nid;
			id.pid = data.ioc_u32[4];
			printf("%-20s [%d]%s->%s:%d #%d\n",
			       libcfs_id2str(id),
			       data.ioc_count, /* persistence */
			       /* my ip */
			       ptl_ipaddr_2_str(data.ioc_u32[2], buffer[0],
						sizeof(buffer[0]), 1),
			       /* peer ip */
			       ptl_ipaddr_2_str(data.ioc_u32[0], buffer[1],
						sizeof(buffer[1]), 1),
			       data.ioc_u32[1], /* peer port */
			       data.ioc_u32[3]); /* conn_count */
		} else if (g_net_is_compatible(NULL, GNILND, 0)) {
			int disconn = data.ioc_flags >> 16;
			char *state;

			if (disconn)
				state = "D";
			else
				state = data.ioc_flags & 0xffff ? "C" : "U";

			printf("%-20s (%d) %s [%d] %ju sq %d/%d tx %d/%d/%d\n",
			       libcfs_nid2str(data.ioc_nid), /* peer nid */
			       data.ioc_net, /* gemini device id */
			       state, /* peer is Connecting, Up, or Down */
			       data.ioc_count,   /* peer refcount */
			       (uintmax_t)data.ioc_u64[0], /* peerstamp */
			       data.ioc_u32[2], data.ioc_u32[3], /* tx and rx seq */
			       /* fmaq, nfma, nrdma */
			       data.ioc_u32[0], data.ioc_u32[1],
			       data.ioc_u32[4]);
		} else {
			printf("%-20s [%d]\n",
			       libcfs_nid2str(data.ioc_nid), data.ioc_count);
		}
	}

	if (index == 0) {
		if (errno == ENOENT) {
			printf("<no peers>\n");
		} else {
			fprintf(stderr,
				"Error getting peer list: %s: check dmesg.\n",
				strerror(errno));
		}
	}
	return 0;
}

int jt_ptl_add_peer(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	lnet_nid_t nid;
	__u32 ip = 0;
	int port = 0;
	int rc;

	if (!g_net_is_compatible(argv[0], SOCKLND, GNILND, 0))
		return -1;

	if (argc != 4) {
		fprintf(stderr, "usage(tcp,gni): %s nid ipaddr port\n",
			argv[0]);
		return 0;
	}

	nid = libcfs_str2nid(argv[1]);
	if (nid == LNET_NID_ANY) {
		fprintf(stderr, "Can't parse NID: %s\n", argv[1]);
		return -1;
	}

	if (lnet_parse_ipaddr(&ip, argv[2]) != 0) {
		fprintf(stderr, "Can't parse ip addr: %s\n", argv[2]);
		return -1;
	}

	if (lnet_parse_port(&port, argv[3]) != 0) {
		fprintf(stderr, "Can't parse port: %s\n", argv[3]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net    = g_net;
	data.ioc_nid    = nid;
	data.ioc_u32[0] = ip;
	data.ioc_u32[1] = port;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_ADD_PEER, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to add peer: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_del_peer(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	lnet_nid_t nid = LNET_NID_ANY;
	lnet_pid_t pid = LNET_PID_ANY;
	__u32 ip = 0;
	int rc;

	if (!g_net_is_compatible(argv[0], SOCKLND, O2IBLND, GNILND,
				 PTL4LND, 0))
		return -1;

	if (g_net_is_compatible(NULL, SOCKLND, 0)) {
		if (argc > 3) {
			fprintf(stderr, "usage: %s [nid] [ipaddr]\n", argv[0]);
			return 0;
		}
	} else if (argc > 2) {
		fprintf(stderr, "usage: %s [nid]\n", argv[0]);
		return 0;
	}

	if (argc > 1 && !libcfs_str2anynid(&nid, argv[1])) {
		fprintf(stderr, "Can't parse nid: %s\n", argv[1]);
		return -1;
	}

	if (g_net_is_compatible(NULL, SOCKLND, 0)) {
		if (argc > 2 && lnet_parse_ipaddr(&ip, argv[2]) != 0) {
			fprintf(stderr, "Can't parse ip addr: %s\n", argv[2]);
			return -1;
		}
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net    = g_net;
	data.ioc_nid    = nid;
	data.ioc_u32[0] = ip;
	data.ioc_u32[1] = pid;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_DEL_PEER, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to remove peer: %s\n", strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_print_connections(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	struct lnet_process_id id;
	char buffer[2][HOST_NAME_MAX + 1];
	int index;
	int rc;

	if (!g_net_is_compatible(argv[0], SOCKLND, O2IBLND, GNILND, 0))
		return -1;

	for (index = 0; ; index++) {
		LIBCFS_IOC_INIT(data);
		data.ioc_net     = g_net;
		data.ioc_count   = index;

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_GET_CONN, &data);
		if (rc != 0)
			break;

		if (g_net_is_compatible(NULL, SOCKLND, 0)) {
			id.nid = data.ioc_nid;
			id.pid = data.ioc_u32[6];
			printf("%-20s %s[%d]%s->%s:%d %d/%d %s\n",
			       libcfs_id2str(id),
			       (data.ioc_u32[3] == SOCKLND_CONN_ANY) ? "A" :
			       (data.ioc_u32[3] == SOCKLND_CONN_CONTROL) ? "C" :
			       (data.ioc_u32[3] == SOCKLND_CONN_BULK_IN) ? "I" :
			 (data.ioc_u32[3] == SOCKLND_CONN_BULK_OUT) ? "O" : "?",
			       data.ioc_u32[4], /* scheduler */
			       /* local IP addr */
			       ptl_ipaddr_2_str(data.ioc_u32[2], buffer[0],
						sizeof(buffer[0]), 1),
			       /* remote IP addr */
			       ptl_ipaddr_2_str(data.ioc_u32[0], buffer[1],
						sizeof(buffer[1]), 1),
			       data.ioc_u32[1],         /* remote port */
			       data.ioc_count, /* tx buffer size */
			       data.ioc_u32[5], /* rx buffer size */
			       data.ioc_flags ? "nagle" : "nonagle");
		} else if (g_net_is_compatible(NULL, O2IBLND, 0)) {
			printf("%s mtu %d\n",
			       libcfs_nid2str(data.ioc_nid),
			       data.ioc_u32[0]); /* path MTU */
		} else if (g_net_is_compatible(NULL, GNILND, 0)) {
			printf("%-20s [%d]\n",
			       libcfs_nid2str(data.ioc_nid),
			       data.ioc_u32[0] /* device id */);
		} else {
			printf("%s\n", libcfs_nid2str(data.ioc_nid));
		}
	}

	if (index == 0) {
		if (errno == ENOENT) {
			printf("<no connections>\n");
		} else {
			fprintf(stderr,
				"Error getting connection list: %s: check dmesg.\n",
				strerror(errno));
		}
	}
	return 0;
}

int jt_ptl_disconnect(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	lnet_nid_t nid = LNET_NID_ANY;
	__u32 ipaddr = 0;
	int rc;

	if (argc > 3) {
		fprintf(stderr, "usage: %s [nid] [ipaddr]\n", argv[0]);
		return 0;
	}

	if (!g_net_is_compatible(NULL, SOCKLND, O2IBLND, GNILND, 0))
		return 0;

	if (argc >= 2 && !libcfs_str2anynid(&nid, argv[1])) {
		fprintf(stderr, "Can't parse nid %s\n", argv[1]);
		return -1;
	}

	if (g_net_is_compatible(NULL, SOCKLND, 0) && argc >= 3 &&
	    lnet_parse_ipaddr(&ipaddr, argv[2]) != 0) {
		fprintf(stderr, "Can't parse ip addr %s\n", argv[2]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net     = g_net;
	data.ioc_nid     = nid;
	data.ioc_u32[0]  = ipaddr;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_CLOSE_CONNECTION, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to remove connection: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int jt_ptl_push_connection(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	int rc;
	lnet_nid_t nid = LNET_NID_ANY;

	if (argc > 2) {
		fprintf(stderr, "usage: %s [nid]\n", argv[0]);
		return 0;
	}

	if (!g_net_is_compatible(argv[0], SOCKLND, GNILND, 0))
		return -1;

	if (argc > 1 && !libcfs_str2anynid(&nid, argv[1])) {
		fprintf(stderr, "Can't parse nid: %s\n", argv[1]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net     = g_net;
	data.ioc_nid     = nid;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_PUSH_CONNECTION, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to push connection: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

#ifndef IOC_LIBCFS_PING_PEER
#define IOC_LIBCFS_PING_PEER		_IOWR('e', 62, IOCTL_LIBCFS_TYPE)
#endif

int jt_ptl_ping(int argc, char **argv)
{
	bool done = false, print = true;
	int rc;
	int timeout;
	struct lnet_process_id id;
	yaml_emitter_t request;
	yaml_parser_t reply;
	yaml_event_t event;
	struct nl_sock *sk;
	char *sep;

	if (argc < 2) {
		fprintf(stderr, "usage: %s id [timeout (secs)]\n", argv[0]);
		return -EINVAL;
	}

	sep = strchr(argv[1], '-');
	if (!sep) {
		rc = lnet_parse_nid(argv[1], &id);
		if (rc != 0)
			return -EINVAL;
	} else {
		char   *end;

		if (argv[1][0] == 'u' || argv[1][0] == 'U')
			id.pid = strtoul(&argv[1][1], &end, 0) |
				LNET_PID_USERFLAG;
		else
			id.pid = strtoul(argv[1], &end, 0);

		if (end != sep) { /* assuming '-' is part of hostname */
			rc = lnet_parse_nid(argv[1], &id);
			if (rc != 0)
				return -EINVAL;
		} else {
			id.nid = libcfs_str2nid(sep + 1);

			if (id.nid == LNET_NID_ANY) {
				fprintf(stderr,
					"Can't parse process id \"%s\"\n",
					argv[1]);
				return -EINVAL;
			}
		}
	}

	if (argc > 2) {
		timeout = 1000 * atol(argv[2]);
		if (timeout > 120 * 1000) {
			fprintf(stderr, "Timeout %s is to large\n",
				argv[2]);
			return -EINVAL;
		}
	} else {
		timeout = 1000; /* default 1 second timeout */
	}

	/* Create Netlink emitter to send request to kernel */
	sk = nl_socket_alloc();
	if (!sk)
		goto old_api;

	/* Setup parser to recieve Netlink packets */
	rc = yaml_parser_initialize(&reply);
	if (rc == 0)
		goto old_api;

	rc = yaml_parser_set_input_netlink(&reply, sk, false);
	if (rc == 0)
		goto free_reply;

	/* Create Netlink emitter to send request to kernel */
	rc = yaml_emitter_initialize(&request);
	if (rc == 0)
		goto free_reply;

	rc = yaml_emitter_set_output_netlink(&request, sk, LNET_GENL_NAME,
					     LNET_GENL_VERSION, LNET_CMD_PING,
					     NLM_F_DUMP);
	if (rc == 0)
		goto emitter_error;

	yaml_emitter_open(&request);
	yaml_document_start_event_initialize(&event, NULL, NULL, NULL, 0);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_start_event_initialize(&event, NULL,
					    (yaml_char_t *)YAML_MAP_TAG,
					    1, YAML_ANY_MAPPING_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_scalar_event_initialize(&event, NULL,
				     (yaml_char_t *)YAML_STR_TAG,
				     (yaml_char_t *)"ping",
				     strlen("ping"), 1, 0,
				     YAML_PLAIN_SCALAR_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_start_event_initialize(&event, NULL,
					    (yaml_char_t *)YAML_MAP_TAG,
					    1, YAML_ANY_MAPPING_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	if (timeout != 1000) {
		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)"timeout",
					     strlen("timeout"), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_INT_TAG,
					     (yaml_char_t *)argv[2],
					     strlen(argv[2]), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&request, &event);
		if (rc == 0)
			goto emitter_error;
	}

	yaml_scalar_event_initialize(&event, NULL,
				     (yaml_char_t *)YAML_STR_TAG,
				     (yaml_char_t *)"nids",
				     strlen("nids"), 1, 0,
				     YAML_PLAIN_SCALAR_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_sequence_start_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_SEQ_TAG,
					     1, YAML_FLOW_SEQUENCE_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	/* convert NID to string, in case libcfs_str2nid() did name lookup */
	yaml_scalar_event_initialize(&event, NULL,
				     (yaml_char_t *)YAML_STR_TAG,
				     (yaml_char_t *)libcfs_nid2str(id.nid),
				     strlen(libcfs_nid2str(id.nid)), 1, 0,
				     YAML_PLAIN_SCALAR_STYLE);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_sequence_end_event_initialize(&event);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_end_event_initialize(&event);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_end_event_initialize(&event);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_document_end_event_initialize(&event, 0);
	rc = yaml_emitter_emit(&request, &event);
	if (rc == 0)
		goto emitter_error;

	rc = yaml_emitter_close(&request);
emitter_error:
	if (rc == 0) {
		yaml_emitter_log_error(&request, stderr);
		rc = -EINVAL;
		goto old_api;
	}
	yaml_emitter_delete(&request);

	/* Now parse the reply results */
	while (!done) {
		rc = yaml_parser_parse(&reply, &event);
		if (rc == 0)
			break;

		if (event.type != YAML_SCALAR_EVENT)
			goto skip;

		if (strcmp((char *)event.data.scalar.value, "nid") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(&reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}
			if (print) {
				/* Print 0@lo. Its not sent */
				printf("12345-0@lo\n");
				print = false;
			}
			printf("%s\n", (char *)event.data.scalar.value);
		} else if (strcmp((char *)event.data.scalar.value,
				  "errno") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(&reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}
			rc = strtol((char *)event.data.scalar.value, NULL, 10);
			fprintf(stdout, "failed to ping %s: %s\n",
				argv[1], strerror(-rc));
			break; /* "rc" is clobbered if loop is run again */
		}
skip:
		done = (event.type == YAML_STREAM_END_EVENT);
		yaml_event_delete(&event);
	}
free_reply:
	if (rc == 0) {
		/* yaml_* functions return 0 for error */
		const char *msg = yaml_parser_get_reader_error(&reply);

		rc = errno ? -errno : -EHOSTUNREACH;
		if (strcmp(msg, "Unspecific failure") != 0) {
			fprintf(stdout, "failed to ping %s: %s\n",
				argv[1], msg);
		} else {
			fprintf(stdout, "failed to ping %s: %s\n",
				argv[1], strerror(errno));
		}
	} else if (rc == 1) {
		/* yaml_* functions return 1 for success */
		rc = 0;
	}
	yaml_parser_delete(&reply);
	nl_socket_free(sk);
	return rc;
old_api:
#ifdef IOC_LIBCFS_PING_PEER
	{
	struct lnet_process_id ids[LNET_INTERFACES_MAX_DEFAULT];
	int maxids = sizeof(ids) / sizeof(ids[0]);
	struct lnet_ioctl_ping_data ping = { { 0 } };
	int i;

	if (sk)
		nl_socket_free(sk);

	LIBCFS_IOC_INIT_V2(ping, ping_hdr);
	ping.ping_hdr.ioc_len = sizeof(ping);
	ping.ping_id = id;
	ping.ping_src = LNET_NID_ANY;
	ping.op_param = timeout;
	ping.ping_count = maxids;
	ping.ping_buf = ids;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_PING_PEER, &ping);
	if (rc != 0) {
		fprintf(stderr, "failed to ping %s: %s\n", argv[1],
			strerror(errno));
		return rc;
	}

	for (i = 0; i < ping.ping_count && i < maxids; i++)
		printf("%s\n", libcfs_id2str(ids[i]));

	if (ping.ping_count > maxids)
		printf("%d out of %d ids listed\n", maxids, ping.ping_count);
	}
#else
	rc = -ENOTTY;
#endif
	return rc;
}

int jt_ptl_mynid(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	lnet_nid_t nid;
	int rc;

	if (argc != 2) {
		fprintf(stderr, "usage: %s NID\n", argv[0]);
		return 0;
	}

	nid = libcfs_str2nid(argv[1]);
	if (nid == LNET_NID_ANY) {
		fprintf(stderr, "Can't parse NID '%s'\n", argv[1]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_net = LNET_NIDNET(nid);
	data.ioc_nid = nid;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_REGISTER_MYNID, &data);
	if (rc < 0)
		fprintf(stderr, "setting my NID failed: %s\n",
			strerror(errno));
	else
		printf("registered my nid %s\n", libcfs_nid2str(nid));

	return 0;
}

int
jt_ptl_fail_nid(int argc, char **argv)
{
	int rc;
	lnet_nid_t nid;
	int threshold;
	struct libcfs_ioctl_data data;

	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: %s nid|\"*\" [count (0 == mend)]\n",
			argv[0]);
		return 0;
	}

	if (!libcfs_str2anynid(&nid, argv[1])) {
		fprintf(stderr, "Can't parse nid \"%s\"\n", argv[1]);
		return -1;
	}

	if (argc < 3) {
		threshold = LNET_MD_THRESH_INF;
	} else if (sscanf(argv[2], "%i", &threshold) != 1) {
		fprintf(stderr, "Can't parse count \"%s\"\n", argv[2]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_nid = nid;
	data.ioc_count = threshold;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_FAIL_NID, &data);
	if (rc < 0)
		fprintf(stderr, "IOC_LIBCFS_FAIL_NID failed: %s\n",
			strerror(errno));
	else
		printf("%s %s\n",
		       threshold == 0 ? "Unfailing" : "Failing", argv[1]);

	return 0;
}

static int ptl_yaml_route_display(yaml_parser_t *reply)
{
	char gw[LNET_MAX_STR_LEN], net[18];
	bool done = false, alive = false;
	int hops = -1, prio = -1;
	yaml_event_t event;
	int rc;

	/* Now parse the reply results */
	while (!done) {
		char *value;

		rc = yaml_parser_parse(reply, &event);
		if (rc == 0)
			break;

		if (event.type == YAML_SEQUENCE_END_EVENT) {
			printf("net %18s hops %d gw %32.128s %s pri %u\n",
			       net, hops, gw, alive ? "up" : "down",
			       prio);
			memset(net, '\0', sizeof(net));
			memset(gw, '\0', sizeof(gw));
			prio = -1;
			hops = -1;
		}

		if (event.type != YAML_SCALAR_EVENT)
			goto skip;

		value = (char *)event.data.scalar.value;
		if (strcmp(value, "net") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}

			value = (char *)event.data.scalar.value;
			strncpy(net, value, sizeof(net) - 1);
		} else if (strcmp(value, "gateway") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}

			value = (char *)event.data.scalar.value;
			strncpy(gw, value, sizeof(gw) - 1);
		} else if (strcmp(value, "state") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}

			value = (char *)event.data.scalar.value;
			if (strcmp(value, "up") == 0) {
				alive = true;
			} else if (strcmp(value, "down") == 0) {
				alive = false;
			}
		} else if (strcmp(value, "hop") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}

			value = (char *)event.data.scalar.value;
			hops = strtol(value, NULL, 10);
		} else if (strcmp(value, "priority") == 0) {
			yaml_event_delete(&event);
			rc = yaml_parser_parse(reply, &event);
			if (rc == 0) {
				yaml_event_delete(&event);
				goto free_reply;
			}

			value = (char *)event.data.scalar.value;
			prio = strtol(value, NULL, 10);
		}
skip:
		done = (event.type == YAML_STREAM_END_EVENT);
		yaml_event_delete(&event);
	}

free_reply:
	return rc;
}

static int ptl_yaml_route(char *nw, char *gws, int hops, int prio, bool enable,
			  time_t notify_time, int flags, int version)
{
	struct nl_sock *sk = NULL;
	const char *msg = NULL;
	yaml_emitter_t output;
	yaml_parser_t reply;
	yaml_event_t event;
	int rc;

	sk = nl_socket_alloc();
	if (!sk)
		return -EOPNOTSUPP;

	/* Setup parser to receive Netlink packets */
	rc = yaml_parser_initialize(&reply);
	if (rc == 0) {
		nl_socket_free(sk);
		return -EOPNOTSUPP;
	}

	rc = yaml_parser_set_input_netlink(&reply, sk, false);
	if (rc == 0) {
		msg = yaml_parser_get_reader_error(&reply);
		goto free_reply;
	}

	/* Create Netlink emitter to send request to kernel */
	rc = yaml_emitter_initialize(&output);
	if (rc == 0) {
		msg = "failed to initialize emitter";
		goto free_reply;
	}

	rc = yaml_emitter_set_output_netlink(&output, sk, LNET_GENL_NAME,
					     version, LNET_CMD_ROUTES, flags);
	if (rc == 0)
		goto emitter_error;

	yaml_emitter_open(&output);
	yaml_document_start_event_initialize(&event, NULL, NULL, NULL, 0);
	rc = yaml_emitter_emit(&output, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_mapping_start_event_initialize(&event, NULL,
					    (yaml_char_t *)YAML_MAP_TAG,
					    1, YAML_ANY_MAPPING_STYLE);
	rc = yaml_emitter_emit(&output, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_scalar_event_initialize(&event, NULL,
				     (yaml_char_t *)YAML_STR_TAG,
				     (yaml_char_t *)"route",
				     strlen("route"), 1, 0,
				     YAML_PLAIN_SCALAR_STYLE);
	rc = yaml_emitter_emit(&output, &event);
	if (rc == 0)
		goto emitter_error;

	if (nw || gws) {
		yaml_sequence_start_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_SEQ_TAG,
						     1,
						     YAML_BLOCK_SEQUENCE_STYLE);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_mapping_start_event_initialize(&event, NULL,
						    (yaml_char_t *)YAML_MAP_TAG, 1,
						    YAML_BLOCK_MAPPING_STYLE);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;

		if (nw) {
			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)"net",
						     strlen("net"), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;

			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)nw,
						     strlen(nw), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;
		}

		if (gws) {
			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)"gateway",
						     strlen("gateway"), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;

			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)gws,
						     strlen(gws), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;
		}

		if (notify_time) {
			char when[INT_STRING_LEN];

			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)"notify_time",
						     strlen("notify_time"), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;

			snprintf(when, sizeof(when), "%ld", notify_time);
			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_INT_TAG,
						     (yaml_char_t *)when,
						     strlen(when), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
			rc = yaml_emitter_emit(&output, &event);
			if (rc == 0)
				goto emitter_error;
		}

		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)"state",
					     strlen("state"), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;

		if (enable)
			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)"up",
						     strlen("up"), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);
		else
			yaml_scalar_event_initialize(&event, NULL,
						     (yaml_char_t *)YAML_STR_TAG,
						     (yaml_char_t *)"down",
						     strlen("down"), 1, 0,
						     YAML_PLAIN_SCALAR_STYLE);

		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_mapping_end_event_initialize(&event);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;

		yaml_sequence_end_event_initialize(&event);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;
	} else {
		yaml_scalar_event_initialize(&event, NULL,
					     (yaml_char_t *)YAML_STR_TAG,
					     (yaml_char_t *)"",
					     strlen(""), 1, 0,
					     YAML_PLAIN_SCALAR_STYLE);
		rc = yaml_emitter_emit(&output, &event);
		if (rc == 0)
			goto emitter_error;
	}

	yaml_mapping_end_event_initialize(&event);
	rc = yaml_emitter_emit(&output, &event);
	if (rc == 0)
		goto emitter_error;

	yaml_document_end_event_initialize(&event, 0);
	rc = yaml_emitter_emit(&output, &event);
	if (rc == 0)
		goto emitter_error;

	rc = yaml_emitter_close(&output);
emitter_error:
	if (rc == 0) {
		yaml_emitter_log_error(&output, stderr);
		rc = -EINVAL;
	} else {
		if (flags != NLM_F_DUMP) {
			yaml_document_t errmsg;

			rc = yaml_parser_load(&reply, &errmsg);
			if (rc == 1) {
				yaml_emitter_t debug;

				rc = yaml_emitter_initialize(&debug);
				if (rc == 1) {
					yaml_emitter_set_indent(&debug,
								LNET_DEFAULT_INDENT);
					yaml_emitter_set_output_file(&debug,
								     stdout);
					rc = yaml_emitter_dump(&debug,
							       &errmsg);
				} else if (rc == 0) {
					yaml_emitter_log_error(&debug, stderr);
					rc = -EINVAL;
				}
				yaml_emitter_delete(&debug);
			}
			yaml_document_delete(&errmsg);
		} else {
			rc = ptl_yaml_route_display(&reply);
		}
		if (rc == 0)
			msg = yaml_parser_get_reader_error(&reply);
	}
	yaml_emitter_delete(&output);
free_reply:
	if (msg)
		fprintf(stdout, "%s\n", msg);
	yaml_parser_delete(&reply);
	nl_socket_free(sk);

	return rc == 1 ? 0 : rc;
}

int
jt_ptl_add_route(int argc, char **argv)
{
	struct lnet_ioctl_config_data data;
	lnet_nid_t gateway_nid;
	__u32 hops = LNET_UNDEFINED_HOPS;
	unsigned int priority = 0;
	char *end;
	int rc;

	if (argc < 2 || argc > 4) {
		fprintf(stderr, "usage: %s gateway [hopcount [priority]]\n",
			argv[0]);
		return -1;
	}

	if (g_net_is_set(argv[0]) == 0)
		return -1;

	gateway_nid = libcfs_str2nid(argv[1]);
	if (gateway_nid == LNET_NID_ANY) {
		fprintf(stderr, "Can't parse gateway NID \"%s\"\n", argv[1]);
		return -1;
	}

	if (argc > 2) {
		hops = strtol(argv[2], &end, 0);
		if (hops == 0 || hops >= 256 ||
		    (end && *end != 0)) {
			fprintf(stderr, "Can't parse hopcount \"%s\"\n",
				argv[2]);
			return -1;
		}
		if (argc == 4) {
			priority = strtoul(argv[3], &end, 0);
			if (end && *end != 0) {
				fprintf(stderr,
					"Can't parse priority \"%s\"\n",
					argv[3]);
				return -1;
			}
		}
	}

	rc = ptl_yaml_route(libcfs_net2str(g_net), argv[1], hops,
			    priority, false, 0, NLM_F_CREATE, LNET_GENL_VERSION);
	if (rc <= 0) {
		if (rc == -EOPNOTSUPP)
			goto old_api;
		return rc;
	}
old_api:
	LIBCFS_IOC_INIT_V2(data, cfg_hdr);
	data.cfg_net = g_net;
	data.cfg_config_u.cfg_route.rtr_hop = hops;
	data.cfg_nid = gateway_nid;
	data.cfg_config_u.cfg_route.rtr_priority = priority;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_ADD_ROUTE, &data);
	if (rc != 0) {
		fprintf(stderr, "IOC_LIBCFS_ADD_ROUTE failed: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_del_route(int argc, char **argv)
{
	struct lnet_ioctl_config_data data;
	lnet_nid_t nid;
	int rc;

	if (argc != 2) {
		fprintf(stderr, "usage: %s gatewayNID\n", argv[0]);
		return 0;
	}

	if (libcfs_str2anynid(&nid, argv[1]) == 0) {
		fprintf(stderr, "Can't parse gateway NID \"%s\"\n", argv[1]);
		return -1;
	}

	rc = ptl_yaml_route(g_net_set ? libcfs_net2str(g_net) : NULL, argv[1],
			    -1, -1, false, 0, 0, LNET_GENL_VERSION);
	if (rc <= 0) {
		if (rc == -EOPNOTSUPP)
			goto old_api;
		return rc;
	}
old_api:
	LIBCFS_IOC_INIT_V2(data, cfg_hdr);
	data.cfg_net = g_net_set ? g_net : LNET_NET_ANY;
	data.cfg_nid = nid;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_DEL_ROUTE, &data);
	if (rc != 0) {
		fprintf(stderr, "IOC_LIBCFS_DEL_ROUTE (%s) failed: %s\n",
			libcfs_nid2str(nid), strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_notify_router(int argc, char **argv)
{
	struct libcfs_ioctl_data data;
	int enable;
	lnet_nid_t nid;
	int rc;
	struct timeval now;
	time_t when;

	if (argc < 3) {
		fprintf(stderr, "usage: %s targetNID <up/down> [<time>]\n",
			argv[0]);
		return 0;
	}

	nid = libcfs_str2nid(argv[1]);
	if (nid == LNET_NID_ANY) {
		fprintf(stderr, "Can't parse target NID \"%s\"\n", argv[1]);
		return -1;
	}

	if (lnet_parse_bool (&enable, argv[2]) != 0) {
		fprintf(stderr, "Can't parse boolean %s\n", argv[2]);
		return -1;
	}

	gettimeofday(&now, NULL);

	if (argc < 4) {
		when = now.tv_sec;
	} else if (lnet_parse_time(&when, argv[3]) != 0) {
		fprintf(stderr,
			"Can't parse time %s\n Please specify either 'YYYY-MM-DD-HH:MM:SS'\n or an absolute unix time in seconds\n",
			argv[3]);
		return -1;
	} else if (when > now.tv_sec) {
		fprintf(stderr, "%s specifies a time in the future\n",
			argv[3]);
		return -1;
	}

	rc = ptl_yaml_route(g_net_set ? libcfs_net2str(g_net) : NULL, argv[1],
			    -1, -1, enable, when, NLM_F_REPLACE, LNET_GENL_VERSION);
	if (rc <= 0) {
		if (rc == -EOPNOTSUPP)
			goto old_api;
		return rc;
	}
old_api:
	LIBCFS_IOC_INIT(data);
	data.ioc_nid = nid;
	data.ioc_flags = enable;
	/* Yeuch; 'cept I need a __u64 on 64 bit machines... */
	data.ioc_u64[0] = (__u64)when;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_NOTIFY_ROUTER, &data);
	if (rc != 0) {
		fprintf(stderr, "IOC_LIBCFS_NOTIFY_ROUTER (%s) failed: %s\n",
			libcfs_nid2str(nid), strerror(errno));
		return -1;
	}

	return 0;
}

int
jt_ptl_print_routes(int argc, char **argv)
{
	struct lnet_ioctl_config_data  data;
	int rc;
	int index;
	__u32 net;
	lnet_nid_t nid;
	int hops;
	int alive;
	unsigned int pri;

	rc = ptl_yaml_route(NULL, NULL, -1, -1, false, 0, NLM_F_DUMP,
			    LNET_GENL_VERSION);
	if (rc <= 0) {
		if (rc == -EOPNOTSUPP)
			goto old_api;
		return rc;
	}
old_api:
	for (index = 0; ; index++) {
		LIBCFS_IOC_INIT_V2(data, cfg_hdr);
		data.cfg_count = index;

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_GET_ROUTE, &data);
		if (rc != 0)
			break;

		net     = data.cfg_net;
		hops    = data.cfg_config_u.cfg_route.rtr_hop;
		nid     = data.cfg_nid;
		alive   = data.cfg_config_u.cfg_route.rtr_flags & LNET_RT_ALIVE;
		pri     = data.cfg_config_u.cfg_route.rtr_priority;

		printf("net %18s hops %d gw %32s %s pri %u\n",
		       libcfs_net2str(net), hops,
		       libcfs_nid2str(nid), alive ? "up" : "down", pri);
	}

	if (errno != ENOENT)
		fprintf(stderr, "Error getting routes: %s: check dmesg.\n",
			strerror(errno));

	return 0;
}

static int
fault_attr_nid_parse(char *str, lnet_nid_t *nid_p)
{
	lnet_nid_t nid;
	__u32 net;
	int rc = 0;

	/* NB: can't support range ipaddress except * and *@net */
	if (strlen(str) > 2 && str[0] == '*' && str[1] == '@') {
		net = libcfs_str2net(str + 2);
		if (net == LNET_NET_ANY)
			goto failed;

		nid = LNET_MKNID(net, LNET_NIDADDR(LNET_NID_ANY));
	} else {
		rc = libcfs_str2anynid(&nid, str);
		if (!rc)
			goto failed;
	}

	*nid_p = nid;
	return 0;
failed:
	fprintf(stderr, "Invalid NID : %s\n", str);
	return -1;
}

static int
fault_attr_msg_parse(char *msg_str, __u32 *mask_p)
{
	if (!strcasecmp(msg_str, "put")) {
		*mask_p |= LNET_PUT_BIT;
		return 0;

	} else if (!strcasecmp(msg_str, "ack")) {
		*mask_p |= LNET_ACK_BIT;
		return 0;

	} else if (!strcasecmp(msg_str, "get")) {
		*mask_p |= LNET_GET_BIT;
		return 0;

	} else if (!strcasecmp(msg_str, "reply")) {
		*mask_p |= LNET_REPLY_BIT;
		return 0;
	}

	fprintf(stderr, "unknown message type %s\n", msg_str);
	return -1;
}

static int
fault_attr_ptl_parse(char *ptl_str, __u64 *mask_p)
{
	unsigned long rc = strtoul(optarg, NULL, 0);

	if (rc >= 64) {
		fprintf(stderr, "invalid portal: %lu\n", rc);
		return -1;
	}

	*mask_p |= (1ULL << rc);
	return 0;
}

static int
fault_attr_health_error_parse(char *error, __u32 *mask)
{
	if (!strcasecmp(error, "local_interrupt")) {
		*mask |= HSTATUS_LOCAL_INTERRUPT_BIT;
		return 0;
	}
	if (!strcasecmp(error, "local_dropped")) {
		*mask |= HSTATUS_LOCAL_DROPPED_BIT;
		return 0;
	}
	if (!strcasecmp(error, "local_aborted")) {
		*mask |= HSTATUS_LOCAL_ABORTED_BIT;
		return 0;
	}
	if (!strcasecmp(error, "local_no_route")) {
		*mask |= HSTATUS_LOCAL_NO_ROUTE_BIT;
		return 0;
	}
	if (!strcasecmp(error, "local_error")) {
		*mask |= HSTATUS_LOCAL_ERROR_BIT;
		return 0;
	}
	if (!strcasecmp(error, "local_timeout")) {
		*mask |= HSTATUS_LOCAL_TIMEOUT_BIT;
		return 0;
	}
	if (!strcasecmp(error, "remote_error")) {
		*mask |= HSTATUS_REMOTE_ERROR_BIT;
		return 0;
	}
	if (!strcasecmp(error, "remote_dropped")) {
		*mask |= HSTATUS_REMOTE_DROPPED_BIT;
		return 0;
	}
	if (!strcasecmp(error, "remote_timeout")) {
		*mask |= HSTATUS_REMOTE_TIMEOUT_BIT;
		return 0;
	}
	if (!strcasecmp(error, "network_timeout")) {
		*mask |= HSTATUS_NETWORK_TIMEOUT_BIT;
		return 0;
	}
	if (!strcasecmp(error, "random")) {
		*mask = HSTATUS_RANDOM;
		return 0;
	}

	return -1;
}

static int
fault_simul_rule_add(__u32 opc, char *name, int argc, char **argv)
{
	struct libcfs_ioctl_data  data = { { 0 } };
	struct lnet_fault_attr    attr;
	char *optstr;
	int rc;

	static const struct option opts[] = {
	{ .name = "source",   .has_arg = required_argument, .val = 's' },
	{ .name = "dest",     .has_arg = required_argument, .val = 'd' },
	{ .name = "rate",     .has_arg = required_argument, .val = 'r' },
	{ .name = "interval", .has_arg = required_argument, .val = 'i' },
	{ .name = "random",   .has_arg = no_argument,       .val = 'n' },
	{ .name = "latency",  .has_arg = required_argument, .val = 'l' },
	{ .name = "portal",   .has_arg = required_argument, .val = 'p' },
	{ .name = "message",  .has_arg = required_argument, .val = 'm' },
	{ .name = "health_error",  .has_arg = required_argument, .val = 'e' },
	{ .name = "local_nid",  .has_arg = required_argument, .val = 'o' },
	{ .name = "drop_all",  .has_arg = no_argument, .val = 'x' },
	{ .name = NULL } };

	if (argc == 1) {
		fprintf(stderr,
			"Failed, please provide source, destination and rate of rule\n");
		return -1;
	}

	optstr = opc == LNET_CTL_DROP_ADD ? "s:d:o:r:i:p:m:e:nx" : "s:d:o:r:l:p:m:";
	memset(&attr, 0, sizeof(attr));
	while (1) {
		int c = getopt_long(argc, argv, optstr, opts, NULL);

		if (c == -1)
			break;

		switch (c) {
		case 'o':
			rc = fault_attr_nid_parse(optarg, &attr.fa_local_nid);
			if (rc != 0)
				goto getopt_failed;
			break;
		case 's': /* source NID/NET */
			rc = fault_attr_nid_parse(optarg, &attr.fa_src);
			if (rc != 0)
				goto getopt_failed;
			break;

		case 'd': /* dest NID/NET */
			rc = fault_attr_nid_parse(optarg, &attr.fa_dst);
			if (rc != 0)
				goto getopt_failed;
			break;

		case 'r': /* drop rate */
			if (opc == LNET_CTL_DROP_ADD)
				attr.u.drop.da_rate = strtoul(optarg, NULL, 0);
			else
				attr.u.delay.la_rate = strtoul(optarg, NULL, 0);
			break;

		case 'e':
			if (opc == LNET_CTL_DROP_ADD) {
				rc = fault_attr_health_error_parse(optarg,
								   &attr.u.drop.da_health_error_mask);
				if (rc)
					goto getopt_failed;
			}
			break;

		case 'x':
			if (opc == LNET_CTL_DROP_ADD)
				attr.u.drop.da_drop_all = true;
			break;

		case 'n':
			if (opc == LNET_CTL_DROP_ADD)
				attr.u.drop.da_random = true;
			break;

		case 'i': /* time interval (# seconds) for message drop */
			if (opc == LNET_CTL_DROP_ADD)
				attr.u.drop.da_interval = strtoul(optarg,
								  NULL, 0);
			else
				attr.u.delay.la_interval = strtoul(optarg,
								   NULL, 0);
			break;

		case 'l': /* seconds to wait before activating rule */
			attr.u.delay.la_latency = strtoul(optarg, NULL, 0);
			break;

		case 'p': /* portal to filter */
			rc = fault_attr_ptl_parse(optarg, &attr.fa_ptl_mask);
			if (rc != 0)
				goto getopt_failed;
			break;

		case 'm': /* message types to filter */
			rc = fault_attr_msg_parse(optarg, &attr.fa_msg_mask);
			if (rc != 0)
				goto getopt_failed;
			break;

		default:
			fprintf(stderr, "error: %s: option '%s' unrecognized\n",
				argv[0], argv[optind - 1]);
			goto getopt_failed;
		}
	}
	optind = 1;

	if (opc == LNET_CTL_DROP_ADD) {
		/* NB: drop rate and interval are exclusive to each other */
		if (!((attr.u.drop.da_rate == 0) ^
		      (attr.u.drop.da_interval == 0))) {
			fprintf(stderr,
				"please provide either drop rate or interval but not both at the same time.\n");
			return -1;
		}

		if (attr.u.drop.da_random &&
		    attr.u.drop.da_interval == 0) {
			fprintf(stderr,
				"please provide an interval to randomize\n");
			return -1;
		}
	} else if (opc == LNET_CTL_DELAY_ADD) {
		if (!((attr.u.delay.la_rate == 0) ^
		      (attr.u.delay.la_interval == 0))) {
			fprintf(stderr,
				"please provide either delay rate or interval but not both at the same time.\n");
			return -1;
		}

		if (attr.u.delay.la_latency == 0) {
			fprintf(stderr, "latency cannot be zero\n");
			return -1;
		}
	}

	if (attr.fa_src == 0 || attr.fa_dst == 0) {
		fprintf(stderr,
			"Please provide both source and destination of %s rule\n",
			name);
		return -1;
	}

	if (attr.fa_local_nid == 0)
		attr.fa_local_nid = LNET_NID_ANY;

	data.ioc_flags = opc;
	data.ioc_inllen1 = sizeof(attr);
	data.ioc_inlbuf1 = (char *)&attr;
	if (libcfs_ioctl_pack(&data, &ioc_buf, IOC_BUF_SIZE) != 0) {
		fprintf(stderr, "libcfs_ioctl_pack failed\n");
		return -1;
	}

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_LNET_FAULT, ioc_buf);
	if (rc != 0) {
		fprintf(stderr, "add %s rule %s->%s failed: %s\n",
			name, libcfs_nid2str(attr.fa_src),
			libcfs_nid2str(attr.fa_dst), strerror(errno));
		return -1;
	}

	printf("Added %s rule %s->%s (1/%d)\n",
	       name, libcfs_nid2str(attr.fa_src), libcfs_nid2str(attr.fa_dst),
	       opc == LNET_CTL_DROP_ADD ?
	       attr.u.drop.da_rate : attr.u.delay.la_rate);
	return 0;

getopt_failed:
	optind = 1;
	return -1;
}

int
jt_ptl_drop_add(int argc, char **argv)
{
	return fault_simul_rule_add(LNET_CTL_DROP_ADD, "drop", argc, argv);
}

int
jt_ptl_delay_add(int argc, char **argv)
{
	return fault_simul_rule_add(LNET_CTL_DELAY_ADD, "delay", argc, argv);
}

static int
fault_simul_rule_del(__u32 opc, char *name, int argc, char **argv)
{
	struct libcfs_ioctl_data data = { { 0 } };
	struct lnet_fault_attr   attr;
	bool all = false;
	int rc;

	static const struct option opts[] = {
		{ .name = "source", .has_arg = required_argument, .val = 's' },
		{ .name = "dest",   .has_arg = required_argument, .val = 'd' },
		{ .name = "all",    .has_arg = no_argument,	  .val = 'a' },
		{ .name = NULL } };

	if (argc == 1) {
		fprintf(stderr,
			"Failed, please provide source and destination of rule\n");
		return -1;
	}

	memset(&attr, 0, sizeof(attr));
	while (1) {
		int c = getopt_long(argc, argv, "s:d:a", opts, NULL);

		if (c == -1 || all)
			break;

		switch (c) {
		case 's':
			rc = fault_attr_nid_parse(optarg, &attr.fa_src);
			if (rc != 0)
				goto getopt_failed;
			break;
		case 'd':
			rc = fault_attr_nid_parse(optarg, &attr.fa_dst);
			if (rc != 0)
				goto getopt_failed;
			break;
		case 'a':
			attr.fa_src = 0;
			attr.fa_dst = 0;
			all = true;

			break;
		default:
			fprintf(stderr, "error: %s: option '%s' unrecognized\n",
				argv[0], argv[optind - 1]);
			goto getopt_failed;
		}
	}
	optind = 1;

	data.ioc_flags = opc;
	data.ioc_inllen1 = sizeof(attr);
	data.ioc_inlbuf1 = (char *)&attr;
	if (libcfs_ioctl_pack(&data, &ioc_buf, IOC_BUF_SIZE) != 0) {
		fprintf(stderr, "libcfs_ioctl_pack failed\n");
		return -1;
	}

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_LNET_FAULT, ioc_buf);
	if (rc != 0) {
		fprintf(stderr, "remove %s rule %s->%s failed: %s\n", name,
			all ? "all" : libcfs_nid2str(attr.fa_src),
			all ? "all" : libcfs_nid2str(attr.fa_dst),
			strerror(errno));
		return -1;
	}

	libcfs_ioctl_unpack(&data, ioc_buf);
	printf("Removed %d %s rules\n", data.ioc_count, name);
	return 0;

getopt_failed:
	optind = 1;
	return -1;
}

int
jt_ptl_drop_del(int argc, char **argv)
{
	return fault_simul_rule_del(LNET_CTL_DROP_DEL, "drop", argc, argv);
}

int
jt_ptl_delay_del(int argc, char **argv)
{
	return fault_simul_rule_del(LNET_CTL_DELAY_DEL, "delay", argc, argv);
}

static int
fault_simul_rule_reset(__u32 opc, char *name, int argc, char **argv)
{
	struct libcfs_ioctl_data   data = { { 0 } };
	int			   rc;

	LIBCFS_IOC_INIT(data);
	data.ioc_flags = opc;

	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_LNET_FAULT, &data);
	if (rc != 0) {
		fprintf(stderr, "failed to reset %s stats: %s\n",
			name, strerror(errno));
		return -1;
	}
	return 0;
}

int
jt_ptl_drop_reset(int argc, char **argv)
{
	return fault_simul_rule_reset(LNET_CTL_DROP_RESET, "drop", argc, argv);
}

int
jt_ptl_delay_reset(int argc, char **argv)
{
	return fault_simul_rule_reset(LNET_CTL_DELAY_RESET, "delay",
				      argc, argv);
}

static int
fault_simul_rule_list(__u32 opc, char *name, int argc, char **argv)
{
	struct libcfs_ioctl_data data = { { 0 } };
	struct lnet_fault_attr   attr;
	struct lnet_fault_stat   stat;
	int pos;

	printf("LNet %s rules:\n", name);
	for (pos = 0;; pos++) {
		int rc;

		memset(&attr, 0, sizeof(attr));
		memset(&stat, 0, sizeof(stat));

		data.ioc_count = pos;
		data.ioc_flags = opc;
		data.ioc_inllen1 = sizeof(attr);
		data.ioc_inlbuf1 = (char *)&attr;
		data.ioc_inllen2 = sizeof(stat);
		data.ioc_inlbuf2 = (char *)&stat;
		if (libcfs_ioctl_pack(&data, &ioc_buf, IOC_BUF_SIZE) != 0) {
			fprintf(stderr, "libcfs_ioctl_pack failed\n");
			return -1;
		}

		rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_LNET_FAULT, ioc_buf);
		if (rc != 0)
			break;

		libcfs_ioctl_unpack(&data, ioc_buf);

		if (opc == LNET_CTL_DROP_LIST) {
			printf("%s->%s (1/%d | %d) ptl %#jx, msg %x, %ju/%ju, PUT %ju, ACK %ju, GET %ju, REP %ju\n",
			       libcfs_nid2str(attr.fa_src),
			       libcfs_nid2str(attr.fa_dst),
			       attr.u.drop.da_rate, attr.u.drop.da_interval,
			       (uintmax_t)attr.fa_ptl_mask, attr.fa_msg_mask,
			       (uintmax_t)stat.u.drop.ds_dropped,
			       (uintmax_t)stat.fs_count,
			       (uintmax_t)stat.fs_put,
			       (uintmax_t)stat.fs_ack,
			       (uintmax_t)stat.fs_get,
			       (uintmax_t)stat.fs_reply);

		} else if (opc == LNET_CTL_DELAY_LIST) {
			printf("%s->%s (1/%d | %d, latency %d) ptl %#jx, msg %x, %ju/%ju, PUT %ju, ACK %ju, GET %ju, REP %ju\n",
			       libcfs_nid2str(attr.fa_src),
			       libcfs_nid2str(attr.fa_dst),
			       attr.u.delay.la_rate, attr.u.delay.la_interval,
			       attr.u.delay.la_latency,
			       (uintmax_t)attr.fa_ptl_mask, attr.fa_msg_mask,
			       (uintmax_t)stat.u.delay.ls_delayed,
			       (uintmax_t)stat.fs_count,
			       (uintmax_t)stat.fs_put,
			       (uintmax_t)stat.fs_ack,
			       (uintmax_t)stat.fs_get,
			       (uintmax_t)stat.fs_reply);
		}
	}
	printf("found total %d\n", pos);

	return 0;
}

int
jt_ptl_drop_list(int argc, char **argv)
{
	return fault_simul_rule_list(LNET_CTL_DROP_LIST, "drop", argc, argv);
}

int
jt_ptl_delay_list(int argc, char **argv)
{
	return fault_simul_rule_list(LNET_CTL_DELAY_LIST, "delay", argc, argv);
}

double
get_cycles_per_usec()
{
	FILE *f = fopen("/proc/cpuinfo", "r");
	double mhz;
	char line[64];

	if (f) {
		while (fgets(line, sizeof(line), f))
			if (sscanf(line, "cpu MHz : %lf", &mhz) == 1) {
				fclose(f);
				return mhz;
			}
		fclose(f);
	}

	fprintf(stderr, "Can't read/parse /proc/cpuinfo\n");
	return 1000.0;
}

int jt_ptl_testprotocompat(int argc, char **argv)
{
	struct libcfs_ioctl_data  data;
	int rc;
	int flags;
	char *end;

	if (argc < 2)  {
		fprintf(stderr, "usage: %s <number>\n", argv[0]);
		return 0;
	}

	flags = strtol(argv[1], &end, 0);
	if (flags < 0 || *end != 0) {
		fprintf(stderr, "Can't parse flags '%s'\n", argv[1]);
		return -1;
	}

	LIBCFS_IOC_INIT(data);
	data.ioc_flags = flags;
	rc = l_ioctl(LNET_DEV_ID, IOC_LIBCFS_TESTPROTOCOMPAT, &data);

	if (rc != 0) {
		fprintf(stderr, "test proto compat %x failed: %s\n",
			flags, strerror(errno));
		return -1;
	}

	printf("test proto compat %x OK\n", flags);
	return 0;
}
