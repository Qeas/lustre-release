/*
 * GPL HEADER START
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 only,
 * as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License version 2 for more details (a copy is included
 * in the LICENSE file that accompanied this code).
 *
 * You should have received a copy of the GNU General Public License
 * version 2 along with this program; if not, write to the
 * Free Software Foundation, Inc., 59 Temple Place - Suite 330,
 * Boston, MA 021110-1307, USA
 *
 * GPL HEADER END
 */
/*
 * Copyright (c) 2009, 2010, Oracle and/or its affiliates. All rights reserved.
 *
 * Copyright (c) 2012, 2017, Intel Corporation.
 *
 * Code originally extracted from quota directory
 */

#include <obd_class.h>
#include <lustre_osc.h>

#include "osc_internal.h"

int osc_quota_chkdq(struct client_obd *cli, const unsigned int qid[])
{
	int type;

	ENTRY;
	for (type = 0; type < LL_MAXQUOTAS; type++) {
		u8 *qtype;

		qtype = xa_load(&cli->cl_quota_exceeded_ids, qid[type]);
		if (qtype && (xa_to_value(qtype) & BIT(type))) {
			/* the slot is busy, the user is about to run out of
			 * quota space on this OST
			 */
			CDEBUG(D_QUOTA, "chkdq found noquota for %s %d\n",
			       qtype_name(type), qid[type]);
			RETURN(-EDQUOT);
		}
	}

	RETURN(0);
}

static inline u32 md_quota_flag(int qtype)
{
	switch (qtype) {
	case USRQUOTA:
		return OBD_MD_FLUSRQUOTA;
	case GRPQUOTA:
		return OBD_MD_FLGRPQUOTA;
	case PRJQUOTA:
		return OBD_MD_FLPRJQUOTA;
	default:
		return 0;
	}
}

static inline u32 fl_quota_flag(int qtype)
{
	switch (qtype) {
	case USRQUOTA:
		return OBD_FL_NO_USRQUOTA;
	case GRPQUOTA:
		return OBD_FL_NO_GRPQUOTA;
	case PRJQUOTA:
		return OBD_FL_NO_PRJQUOTA;
	default:
		return 0;
	}
}

int osc_quota_setdq(struct client_obd *cli, u64 xid, const unsigned int qid[],
		    u64 valid, u32 flags)
{
	int type;
	int rc = 0;

        ENTRY;
	if ((valid & (OBD_MD_FLALLQUOTA)) == 0)
		RETURN(0);

	mutex_lock(&cli->cl_quota_mutex);
	cli->cl_root_squash = !!(flags & OBD_FL_ROOT_SQUASH);
	cli->cl_root_prjquota = !!(flags & OBD_FL_ROOT_PRJQUOTA);
	/* still mark the quots is running out for the old request, because it
	 * could be processed after the new request at OST, the side effect is
	 * the following request will be processed synchronously, but it will
	 * not break the quota enforcement. */
	if (cli->cl_quota_last_xid > xid && !(flags & OBD_FL_NO_QUOTA_ALL))
		GOTO(out_unlock, rc);

	if (cli->cl_quota_last_xid < xid)
		cli->cl_quota_last_xid = xid;

	for (type = 0; type < LL_MAXQUOTAS; type++) {
		unsigned long bits = 0;
		u8 *qtypes;

		if ((valid & md_quota_flag(type)) == 0)
			continue;

		/* lookup the quota IDs in the ID xarray */
		qtypes = xa_load(&cli->cl_quota_exceeded_ids, qid[type]);
		if ((flags & fl_quota_flag(type)) != 0) {
			/* This ID is getting close to its quota limit, let's
			 * switch to sync I/O
			 */
			if (qtypes) {
				bits = xa_to_value(qtypes);
				/* test if already set */
				if (bits & BIT(type))
					continue;
			}

			bits |= BIT(type);
			rc = xa_insert(&cli->cl_quota_exceeded_ids, qid[type],
				       xa_mk_value(bits), GFP_KERNEL);
			if (rc)
				break;

			CDEBUG(D_QUOTA, "%s: setdq to insert for %s %d: rc = %d\n",
			       cli_name(cli), qtype_name(type), qid[type], rc);
		} else {
			/* This ID is now off the hook, let's remove it from
			 * the xarray
			 */
			if (!qtypes)
				continue;

			bits = xa_to_value(qtypes);
			if (!(bits & BIT(type)))
				continue;

			bits &= ~BIT(type);
			if (bits) {
				if (xa_cmpxchg(&cli->cl_quota_exceeded_ids,
					       qid[type], qtypes,
					       xa_mk_value(bits),
					       GFP_KERNEL) != qtypes)
					GOTO(out_unlock, rc = -ENOENT);
			} else {
				xa_erase(&cli->cl_quota_exceeded_ids, qid[type]);
			}

			CDEBUG(D_QUOTA, "%s: setdq to remove for %s %d\n",
			       cli_name(cli), qtype_name(type), qid[type]);
		}
	}

out_unlock:
	mutex_unlock(&cli->cl_quota_mutex);
	RETURN(rc);
}

int osc_quota_setup(struct obd_device *obd)
{
	struct client_obd *cli = &obd->u.cli;

	mutex_init(&cli->cl_quota_mutex);

	xa_init(&cli->cl_quota_exceeded_ids);

	return 0;
}

void osc_quota_cleanup(struct obd_device *obd)
{
	struct client_obd *cli = &obd->u.cli;

	xa_destroy(&cli->cl_quota_exceeded_ids);
}

int osc_quotactl(struct obd_device *unused, struct obd_export *exp,
                 struct obd_quotactl *oqctl)
{
        struct ptlrpc_request *req;
        struct obd_quotactl   *oqc;
        int                    rc;
        ENTRY;

        req = ptlrpc_request_alloc_pack(class_exp2cliimp(exp),
                                        &RQF_OST_QUOTACTL, LUSTRE_OST_VERSION,
                                        OST_QUOTACTL);
        if (req == NULL)
                RETURN(-ENOMEM);

        oqc = req_capsule_client_get(&req->rq_pill, &RMF_OBD_QUOTACTL);
        *oqc = *oqctl;

        ptlrpc_request_set_replen(req);
        ptlrpc_at_set_req_timeout(req);
        req->rq_no_resend = 1;

        rc = ptlrpc_queue_wait(req);
        if (rc)
                CERROR("ptlrpc_queue_wait failed, rc: %d\n", rc);

        if (req->rq_repmsg &&
            (oqc = req_capsule_server_get(&req->rq_pill, &RMF_OBD_QUOTACTL))) {
                *oqctl = *oqc;
        } else if (!rc) {
                CERROR ("Can't unpack obd_quotactl\n");
                rc = -EPROTO;
        }
        ptlrpc_req_finished(req);

        RETURN(rc);
}
