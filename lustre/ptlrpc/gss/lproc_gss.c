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
 * version 2 along with this program; If not, see
 * http://www.gnu.org/licenses/gpl-2.0.html
 *
 * GPL HEADER END
 */
/*
 * Copyright (c) 2007, 2010, Oracle and/or its affiliates. All rights reserved.
 * Use is subject to license terms.
 *
 * Copyright (c) 2012, 2016, Intel Corporation.
 */
/*
 * This file is part of Lustre, http://www.lustre.org/
 */

#define DEBUG_SUBSYSTEM S_SEC
#include <linux/init.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/dcache.h>
#include <linux/fs.h>
#include <linux/mutex.h>

#include <obd.h>
#include <obd_class.h>
#include <obd_support.h>
#include <lustre_net.h>
#include <lustre_import.h>
#include <lprocfs_status.h>
#include <lustre_sec.h>

#include "gss_err.h"
#include "gss_internal.h"
#include "gss_api.h"

static struct dentry *gss_debugfs_dir_lk;
static struct dentry *gss_debugfs_dir;
static struct proc_dir_entry *gss_lprocfs_dir;

/*
 * statistic of "out-of-sequence-window"
 */
static struct {
	spinlock_t	oos_lock;
	atomic_t	oos_cli_count;		/* client occurrence */
	int		oos_cli_behind;		/* client max seqs behind */
	atomic_t	oos_svc_replay[3];	/* server replay detected */
	atomic_t	oos_svc_pass[3];	/* server verified ok */
} gss_stat_oos = {
	.oos_cli_count	= ATOMIC_INIT(0),
	.oos_cli_behind	= 0,
	.oos_svc_replay	= { ATOMIC_INIT(0), },
	.oos_svc_pass	= { ATOMIC_INIT(0), },
};

void gss_stat_oos_record_cli(int behind)
{
	atomic_inc(&gss_stat_oos.oos_cli_count);

	spin_lock(&gss_stat_oos.oos_lock);
	if (behind > gss_stat_oos.oos_cli_behind)
		gss_stat_oos.oos_cli_behind = behind;
	spin_unlock(&gss_stat_oos.oos_lock);
}

void gss_stat_oos_record_svc(int phase, int replay)
{
	LASSERT(phase >= 0 && phase <= 2);

	if (replay)
		atomic_inc(&gss_stat_oos.oos_svc_replay[phase]);
	else
		atomic_inc(&gss_stat_oos.oos_svc_pass[phase]);
}

static int gss_proc_oos_seq_show(struct seq_file *m, void *v)
{
	seq_printf(m, "seqwin:		   %u\n"
		   "backwin:		%u\n"
		   "client fall behind seqwin\n"
		   "  occurrence:	%d\n"
		   "  max seq behind:	%d\n"
		   "server replay detected:\n"
		   "  phase 0:		%d\n"
		   "  phase 1:		%d\n"
		   "  phase 2:		%d\n"
		   "server verify ok:\n"
		   "  phase 2:		%d\n",
		   GSS_SEQ_WIN_MAIN,
		   GSS_SEQ_WIN_BACK,
		   atomic_read(&gss_stat_oos.oos_cli_count),
		   gss_stat_oos.oos_cli_behind,
		   atomic_read(&gss_stat_oos.oos_svc_replay[0]),
		   atomic_read(&gss_stat_oos.oos_svc_replay[1]),
		   atomic_read(&gss_stat_oos.oos_svc_replay[2]),
		   atomic_read(&gss_stat_oos.oos_svc_pass[2]));
	return 0;
}
LDEBUGFS_SEQ_FOPS_RO(gss_proc_oos);

static ssize_t
gss_proc_write_secinit(struct file *file, const char *buffer,
				  size_t count, loff_t *off)
{
        int rc;

        rc = gss_do_ctx_init_rpc((char *) buffer, count);
        if (rc) {
                LASSERT(rc < 0);
                return rc;
        }
	return count;
}

static const struct file_operations gss_proc_secinit = {
	.write = gss_proc_write_secinit,
};

static int
sptlrpc_krb5_allow_old_client_csum_seq_show(struct seq_file *m,
					    void *data)
{
	seq_printf(m, "%u\n", krb5_allow_old_client_csum);
	return 0;
}

static ssize_t
sptlrpc_krb5_allow_old_client_csum_seq_write(struct file *file,
					     const char __user *buffer,
					     size_t count, loff_t *off)
{
	bool val;
	int rc;

	rc = kstrtobool_from_user(buffer, count, &val);
	if (rc)
		return rc;

	krb5_allow_old_client_csum = val;
	return count;
}
LPROC_SEQ_FOPS(sptlrpc_krb5_allow_old_client_csum);

#ifdef HAVE_GSS_KEYRING
static int sptlrpc_gss_check_upcall_ns_seq_show(struct seq_file *m, void *data)
{
	seq_printf(m, "%u\n", gss_check_upcall_ns);
	return 0;
}

static ssize_t sptlrpc_gss_check_upcall_ns_seq_write(struct file *file,
						     const char __user *buffer,
						     size_t count, loff_t *off)
{
	bool val;
	int rc;

	rc = kstrtobool_from_user(buffer, count, &val);
	if (rc)
		return rc;

	gss_check_upcall_ns = val;
	return count;
}
LPROC_SEQ_FOPS(sptlrpc_gss_check_upcall_ns);
#endif /* HAVE_GSS_KEYRING */

static int rsi_upcall_seq_show(struct seq_file *m,
			       void *data)
{
	down_read(&rsicache->uc_upcall_rwsem);
	seq_printf(m, "%s\n", rsicache->uc_upcall);
	up_read(&rsicache->uc_upcall_rwsem);

	return 0;
}

static ssize_t rsi_upcall_seq_write(struct file *file,
				    const char __user *buffer,
				    size_t count, loff_t *off)
{
	int rc;

	if (count >= UC_CACHE_UPCALL_MAXPATH) {
		CERROR("%s: rsi upcall too long\n", rsicache->uc_name);
		return -EINVAL;
	}

	/* Remove any extraneous bits from the upcall (e.g. linefeeds) */
	down_write(&rsicache->uc_upcall_rwsem);
	rc = sscanf(buffer, "%s", rsicache->uc_upcall);
	up_write(&rsicache->uc_upcall_rwsem);

	if (rc != 1) {
		CERROR("%s: invalid rsi upcall provided\n", rsicache->uc_name);
		return -EINVAL;
	}

	CDEBUG(D_CONFIG, "%s: rsi upcall set to %s\n", rsicache->uc_name,
	       rsicache->uc_upcall);

	return count;
}
LPROC_SEQ_FOPS(rsi_upcall);

static ssize_t lprocfs_rsi_flush_seq_write(struct file *file,
					   const char __user *buffer,
					   size_t count, void *data)
{
	int hash, rc;

	rc = kstrtoint_from_user(buffer, count, 0, &hash);
	if (rc)
		return rc;

	rsi_flush(rsicache, hash);
	return count;
}
LPROC_SEQ_FOPS_WR_ONLY(gss, rsi_flush);

static ssize_t lprocfs_rsi_info_seq_write(struct file *file,
					  const char __user *buffer,
					  size_t count, void *data)
{
	struct rsi_downcall_data *param;
	int size = sizeof(*param), rc, checked = 0;

again:
	if (count < size) {
		CERROR("%s: invalid data count = %lu, size = %d\n",
		       rsicache->uc_name, (unsigned long)count, size);
		return -EINVAL;
	}

	OBD_ALLOC_LARGE(param, size);
	if (param == NULL)
		return -ENOMEM;

	if (copy_from_user(param, buffer, size)) {
		CERROR("%s: bad rsi data\n", rsicache->uc_name);
		GOTO(out, rc = -EFAULT);
	}

	if (checked == 0) {
		checked = 1;
		if (param->sid_magic != RSI_DOWNCALL_MAGIC) {
			CERROR("%s: rsi downcall bad params\n",
			       rsicache->uc_name);
			GOTO(out, rc = -EINVAL);
		}

		rc = param->sid_len; /* save sid_len */
		OBD_FREE_LARGE(param, size);
		size = offsetof(struct rsi_downcall_data, sid_val[rc]);
		goto again;
	}

	rc = upcall_cache_downcall(rsicache, param->sid_err,
				   param->sid_hash, param);

out:
	if (param != NULL)
		OBD_FREE_LARGE(param, size);

	return rc ? rc : count;
}
LPROC_SEQ_FOPS_WR_ONLY(gss, rsi_info);

static int rsi_entry_expire_seq_show(struct seq_file *m,
				     void *data)
{
	seq_printf(m, "%lld\n", rsicache->uc_entry_expire);
	return 0;
}

static ssize_t rsi_entry_expire_seq_write(struct file *file,
					  const char __user *buffer,
					  size_t count, loff_t *off)
{
	time64_t val;
	int rc;

	rc = kstrtoll_from_user(buffer, count, 10, &val);
	if (rc)
		return rc;

	if (val < 0)
		return -ERANGE;

	rsicache->uc_entry_expire = val;

	return count;
}
LPROC_SEQ_FOPS(rsi_entry_expire);

static int rsi_acquire_expire_seq_show(struct seq_file *m,
				       void *data)
{
	seq_printf(m, "%lld\n", rsicache->uc_acquire_expire);
	return 0;
}

static ssize_t rsi_acquire_expire_seq_write(struct file *file,
					    const char __user *buffer,
					    size_t count, loff_t *off)
{
	time64_t val;
	int rc;

	rc = kstrtoll_from_user(buffer, count, 10, &val);
	if (rc)
		return rc;

	if (val < 0 || val > INT_MAX)
		return -ERANGE;

	rsicache->uc_acquire_expire = val;

	return count;
}
LPROC_SEQ_FOPS(rsi_acquire_expire);

static struct ldebugfs_vars gss_debugfs_vars[] = {
	{ .name	=	"replays",
	  .fops	=	&gss_proc_oos_fops	},
	{ .name	=	"init_channel",
	  .fops	=	&gss_proc_secinit,
	  .proc_mode =	0222			},
	{ NULL }
};

static struct lprocfs_vars gss_lprocfs_vars[] = {
	{ .name	=	"krb5_allow_old_client_csum",
	  .fops	=	&sptlrpc_krb5_allow_old_client_csum_fops },
#ifdef HAVE_GSS_KEYRING
	{ .name	=	"gss_check_upcall_ns",
	  .fops	=	&sptlrpc_gss_check_upcall_ns_fops },
#endif
	{ .name	=	"rsi_upcall",
	  .fops	=	&rsi_upcall_fops },
	{ .name =	"rsi_flush",
	  .fops =	&gss_rsi_flush_fops },
	{ .name =	"rsi_info",
	  .fops =	&gss_rsi_info_fops },
	{ .name	=	"rsi_entry_expire",
	  .fops	=	&rsi_entry_expire_fops },
	{ .name	=	"rsi_acquire_expire",
	  .fops	=	&rsi_acquire_expire_fops },
	{ NULL }
};

/*
 * for userspace helper lgss_keyring.
 *
 * debug_level: [0, 4], defined in utils/gss/lgss_utils.h
 */
static int gss_lk_debug_level = 1;

static int gss_lk_proc_dl_seq_show(struct seq_file *m, void *v)
{
	seq_printf(m, "%u\n", gss_lk_debug_level);
	return 0;
}

static ssize_t
gss_lk_proc_dl_seq_write(struct file *file, const char __user *buffer,
				size_t count, loff_t *off)
{
	unsigned int val;
	int rc;

	rc = kstrtouint_from_user(buffer, count, 0, &val);
	if (rc < 0)
		return rc;

	if (val > 4)
		return -ERANGE;

	gss_lk_debug_level = val;

	return count;
}
LDEBUGFS_SEQ_FOPS(gss_lk_proc_dl);

static struct ldebugfs_vars gss_lk_debugfs_vars[] = {
	{ .name	=	"debug_level",
	  .fops	=	&gss_lk_proc_dl_fops	},
	{ NULL }
};

void gss_exit_tunables(void)
{
	debugfs_remove_recursive(gss_debugfs_dir_lk);
	gss_debugfs_dir_lk = NULL;

	debugfs_remove_recursive(gss_debugfs_dir);
	gss_debugfs_dir = NULL;

	if (!IS_ERR_OR_NULL(gss_lprocfs_dir))
		lprocfs_remove(&gss_lprocfs_dir);
}

int gss_init_tunables(void)
{
	int	rc;

	spin_lock_init(&gss_stat_oos.oos_lock);

	gss_debugfs_dir = debugfs_create_dir("gss", sptlrpc_debugfs_dir);
	ldebugfs_add_vars(gss_debugfs_dir, gss_debugfs_vars, NULL);

	gss_debugfs_dir_lk = debugfs_create_dir("lgss_keyring",
						gss_debugfs_dir);
	ldebugfs_add_vars(gss_debugfs_dir_lk, gss_lk_debugfs_vars, NULL);

	gss_lprocfs_dir = lprocfs_register("gss", sptlrpc_lprocfs_dir,
					   gss_lprocfs_vars, NULL);
	if (IS_ERR_OR_NULL(gss_lprocfs_dir)) {
		rc = gss_lprocfs_dir ? PTR_ERR(gss_lprocfs_dir) : -ENOMEM;
		gss_lprocfs_dir = NULL;
		GOTO(out, rc);
	}

	return 0;

out:
	CERROR("failed to initialize gss lproc entries: %d\n", rc);
	gss_exit_tunables();
	return rc;
}
