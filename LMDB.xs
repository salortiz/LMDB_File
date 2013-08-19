#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#ifdef	SV_UNDEF_RETURNS_NULL
#define MySvPV(sv, len)	    SvPV_flags(sv, len, SV_GMAGIC|SV_UNDEF_RETURNS_NULL)
#else
#define	MySvPV(sv, len)	    SvOK(sv)?SvPV_flags(sv, len, SV_GMAGIC):((len=0), NULL)
#endif

#ifndef cxinc
#define cxinc()	Perl_cxinc(aTHX)
#endif

#include <lmdb.h>

#include "const-c.inc"

#define	F_ISSET(w, f)	(((w) & (f)) == (f))

static bool
isdbkint(MDB_txn *txn, MDB_dbi dbi)
{
    unsigned int flags = 0;
    mdb_dbi_flags(mdb_txn_env(txn), dbi, &flags);
    return F_ISSET(flags, MDB_INTEGERKEY);
}
#define iscukint(c) isdbkint(mdb_cursor_txn(c), mdb_cursor_dbi(c))

static bool
isdbdint(MDB_txn *txn, MDB_dbi dbi)
{
    unsigned int flags = 0;
    mdb_dbi_flags(mdb_txn_env(txn), dbi, &flags);
    return F_ISSET(flags, MDB_DUPSORT|MDB_INTEGERDUP);
}

#define iscudint(c) isdbdint(mdb_cursor_txn(c), mdb_cursor_dbi(c))

#define StoreUV(k, v)	hv_store(RETVAL, (k), strlen(k), newSVuv(v), 0)

static void
populateStat(HV** hashptr, int res, MDB_stat *stat)
{
    HV* RETVAL;
    if(res) 
	croak(mdb_strerror(res));
    RETVAL = newHV();
    StoreUV("psize", stat->ms_psize);
    StoreUV("depth", stat->ms_depth);
    StoreUV("branch_pages", stat->ms_branch_pages);
    StoreUV("leaf_pages", stat->ms_leaf_pages);
    StoreUV("overflow_pages", stat->ms_overflow_pages);
    StoreUV("entries", stat->ms_entries);
    *hashptr = RETVAL;
}

typedef	MDB_env*    LMDB__Env;
typedef MDB_txn*    LMDB__Txn;
typedef	MDB_txn*    TxnOrNull;
typedef	MDB_dbi	    LMDB;
typedef	MDB_val	    DBD;
typedef	MDB_val	    DBK;
typedef	MDB_val	    DBDC;
typedef	MDB_val	    DBKC;
typedef	MDB_cursor* LMDB__Cursor;
typedef unsigned int flags_t;

static GV *my_lasterr;
static GV *my_errgv;
#define DieOnErr    SvTRUE(GvSV(my_errgv))

static GV *my_agv;
static GV *my_bgv;
static GV *my_cmpgv;
static GV *my_dcmpgv;

static int
LMDB_cmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    dSP;
    int ret;
    ENTER; SAVETMPS;
    PUSHMARK(SP);
    sv_setpvn_mg(GvSV(my_agv), a->mv_data, a->mv_size);
    sv_setpvn_mg(GvSV(my_bgv), b->mv_data, b->mv_size);
    call_sv(SvRV(GvSV(my_cmpgv)), G_SCALAR|G_NOARGS);
    SPAGAIN;
    ret = POPi;
    PUTBACK;
    FREETMPS; LEAVE;
    return ret;
}

#ifdef dMULTICALL

static OP *lmdb_dcmp_cop;
static int
LMDB_dcmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    sv_setpvn_mg(GvSV(my_agv), a->mv_data, a->mv_size);
    sv_setpvn_mg(GvSV(my_bgv), b->mv_data, b->mv_size);
    PL_op = lmdb_dcmp_cop;
    CALLRUNOPS(aTHX);
    return SvIV(*PL_stack_sp);
}

#define dMY_MULTICALL	\
    SV	**newsp;							\
    PERL_CONTEXT *cx;							\
    SV *multicall_sv = NULL;						\
    CV *multicall_cv = NULL;						\
    OP *multicall_cop;							\
    bool multicall_oldcatch = 0; 					\
    U8 hasargs = 0;							\
    I32 gimme = G_SCALAR

#define MY_PUSH_MULTICALL(txn, dbi) \
    multicall_sv = GvSV(my_dcmpgv);					    \
    if(SvROK(multicall_sv) && SvTYPE(SvRV(multicall_sv)) == SVt_PVCV) {	    \
	PUSH_MULTICALL((CV *)SvRV(multicall_sv));			    \
	lmdb_dcmp_cop = multicall_cop;					    \
	mdb_set_dupsort(txn, dbi, LMDB_dcmp);				    \
    }									    \
    if(SvROK(GvSV(my_cmpgv)) && SvTYPE(SvRV(GvSV(my_cmpgv))) == SVt_PVCV) { \
	my_agv = gv_fetchpv("a", GV_ADD, SVt_PV);			    \
	my_bgv = gv_fetchpv("b", GV_ADD, SVt_PV);			    \
	SAVESPTR(GvSV(my_agv));						    \
	SAVESPTR(GvSV(my_bgv));						    \
	mdb_set_compare(txn, dbi, LMDB_cmp);				    \
    }

#define MY_POP_MULTICALL    \
    if(SvROK(multicall_sv) && SvTYPE(SvRV(multicall_sv)) == SVt_PVCV) {	\
	POP_MULTICALL; newsp = newsp;					\
    }

#else /* dMULTICALL */

static int
LMDB_dcmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    dSP;
    int ret;
    ENTER; SAVETMPS;
    PUSHMARK(SP);
    sv_setpvn_mg(GvSV(my_agv), a->mv_data, a->mv_size);
    sv_setpvn_mg(GvSV(my_bgv), b->mv_data, b->mv_size);
    call_sv(SvRV(GvSV(my_dcmpgv)), G_SCALAR|G_NOARGS);
    SPAGAIN;
    ret = POPi;
    PUTBACK;
    FREETMPS; LEAVE;
    return ret;
}

#define	dMY_MULTICALL  \
    int needsave = 0;	\
    SV *my_cmpsv = NULL; \
    SV *my_dcmpsv = NULL

#define MY_PUSH_MULTICALL(txn, dbi) \
    my_dcmpsv = GvSV(my_dcmpgv);				    \
    my_cmpsv = GvSV(my_cmpgv);					    \
    if(SvROK(my_dcmpsv) && SvTYPE(SvRV(my_dcmpsv)) == SVt_PVCV) {   \
	mdb_set_dupsort(tx, dbi, LMDB_dcmp);			    \
	needsave = 1;						    \
    }								    \
    if(SvROK(my_cmpgv) && SvTYPE(SvRV(my_cmpgv)) == SVt_PVCV) {	    \
	mdb_set_compare(txn, dbi, LMDB_cmp);			    \
	needsave = 1;						    \
    }								    \
    if(needsave) {						    \
	my_agv = gv_fetchpv("a", GV_ADD, SVt_PV);		    \
	my_bgv = gv_fetchpv("b", GV_ADD, SVt_PV);		    \
	SAVESPTR(GvSV(my_agv));					    \
	SAVESPTR(GvSV(my_bgv));					    \
    }

#define MY_POP_MULTICALL

#endif	/* dMULTICALL */

#define ProcError(res)   \
    if(res) {					\
	sv_setiv(GvSV(my_lasterr), res);	\
	SV *sv = newSVpvf(mdb_strerror(res));	\
	SvSetSV(ERRSV, sv);			\
	if(DieOnErr) croak(NULL);		\
	XSRETURN_IV(res);			\
    }

MODULE = LMDB_File	PACKAGE = LMDB::Env	PREFIX = mdb_env_

int
mdb_env_create(env)
	LMDB::Env   &env = NO_INIT 
    POSTCALL:
	ProcError(RETVAL);
    OUTPUT:
	env

int
mdb_env_open(env, path, flags, mode)
	LMDB::Env   env
	const char *	path
	flags_t	flags
	int	mode
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_copy(env, path)
	LMDB::Env   env
	const char *	path
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_copyfd(env, fd)
	LMDB::Env   env
	mdb_filehandle_t  fd
    POSTCALL:
	ProcError(RETVAL);

HV*
mdb_env_stat(env)
	LMDB::Env   env
    PREINIT:
	MDB_stat stat;
    CODE:
	populateStat(&RETVAL, mdb_env_stat(env, &stat), &stat);
    OUTPUT:
	RETVAL

HV*
mdb_env_info(env)
	LMDB::Env   env
    PREINIT:
	MDB_envinfo stat;
	int res;
    CODE:
	res = mdb_env_info(env, &stat);
	ProcError(res);
	RETVAL = newHV();
	StoreUV("mapaddr", (uintptr_t)stat.me_mapaddr);
	StoreUV("mapsize", stat.me_mapsize);
	StoreUV("last_pgno", stat.me_last_pgno);
	StoreUV("last_txnid", stat.me_last_txnid);
	StoreUV("maxreaders", stat.me_maxreaders);
	StoreUV("numreaders", stat.me_numreaders);
    OUTPUT:
	RETVAL

int
mdb_env_sync(env, force)
	LMDB::Env   env
	int	force

void
mdb_env_close(env)
	LMDB::Env   env

int
mdb_env_set_flags(env, flags, onoff)
	LMDB::Env   env
	unsigned int	flags
	int	onoff

int
mdb_env_get_flags(env, flags)
	LMDB::Env   env
	unsigned int &flags = NO_INIT
    OUTPUT:
	flags

int
mdb_env_get_path(env, path)
	LMDB::Env   env
	const char * &path = NO_INIT
    OUTPUT:
	path

int
mdb_env_set_mapsize(env, size)
	LMDB::Env   env
	size_t	size
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_set_maxreaders(env, readers)
	LMDB::Env   env
	unsigned int	readers
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_get_maxreaders(env, readers)
	LMDB::Env   env
	unsigned int &readers = NO_INIT
    OUTPUT:
	readers
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_set_maxdbs(env, dbs)
	LMDB::Env   env
	int	dbs
    POSTCALL:
	ProcError(RETVAL);

int
mdb_env_get_maxkeysize(env)
	LMDB::Env   env

UV
mdb_env_id(env)
	LMDB::Env   env
    CODE:
	RETVAL = (UV)env;
    OUTPUT:
	RETVAL

MODULE = LMDB_File	PACKAGE = LMDB::Txn	PREFIX = mdb_txn

int
mdb_txn_begin(env, parent, flags, txn)
	LMDB::Env   env
	TxnOrNull   parent
	unsigned int	flags
	LMDB::Txn   	&txn = NO_INIT
    POSTCALL:
	ProcError(RETVAL);
    OUTPUT:
	txn

UV
mdb_txn_env(txn)
	LMDB::Txn   txn
    CODE:
	RETVAL= (UV)mdb_txn_env(txn);
    OUTPUT:
	RETVAL

int
mdb_txn_commit(txn)
	LMDB::Txn   txn
    POSTCALL:
	ProcError(RETVAL);

void
mdb_txn_abort(txn)
	LMDB::Txn   txn

void
mdb_txn_reset(txn)
	LMDB::Txn   txn

int
mdb_txn_renew(txn)
	LMDB::Txn   txn
    POSTCALL:
	ProcError(RETVAL);

UV
mdb_txn_id(txn)
	LMDB::Txn   txn
    CODE:
	RETVAL = (UV)txn;
    OUTPUT:
	RETVAL

MODULE = LMDB_File	PACKAGE = LMDB::Cursor	PREFIX = mdb_cursor_

void
mdb_cursor_close(cursor)
	LMDB::Cursor	cursor

int
mdb_cursor_count(cursor, count)
	LMDB::Cursor	cursor
	UV  &count = NO_INIT
    OUTPUT:
	count

int
mdb_cursor_dbi(cursor)
	LMDB::Cursor	cursor

int
mdb_cursor_del(cursor, flags)
	LMDB::Cursor	cursor
	unsigned int	flags

int
mdb_cursor_get(cursor, key, data, op)
	LMDB::Cursor	cursor
	DBKC	&key	
	DBDC	&data
	MDB_cursor_op	op
    POSTCALL:
	ProcError(RETVAL);
    OUTPUT:
	key
	data

int
mdb_cursor_open(txn, dbi, cursor)
	LMDB::Txn   txn
	LMDB	dbi
	LMDB::Cursor	&cursor = NO_INIT
    OUTPUT:
	cursor

int
mdb_cursor_put(cursor, key, data, flags)
	LMDB::Cursor	cursor
	DBKC	&key
	DBDC	&data
	unsigned int	flags
    POSTCALL:
	ProcError(RETVAL);

int
mdb_cursor_renew(txn, cursor)
	LMDB::Txn   txn
	LMDB::Cursor	cursor

UV
mdb_cursor_txn(cursor)
	LMDB::Cursor	cursor
    CODE:
	RETVAL = (UV)mdb_cursor_txn(cursor);
    OUTPUT:
	RETVAL

MODULE = LMDB_File		PACKAGE = LMDB_File	    PREFIX = mdb


#ifdef __GNUC__
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif

INCLUDE: const-xs.inc

#ifdef __GNUC__
#pragma GCC diagnostic warning "-Wmaybe-uninitialized"
#endif

int
mdb_dbi_open(txn, name, flags, dbi)
	LMDB::Txn   txn
	const char * name = SvOK($arg) ? (const char *)SvPV_nolen($arg) : NULL;
	flags_t	flags
	LMDB	&dbi = NO_INIT
    POSTCALL:
	ProcError(RETVAL);
    OUTPUT:
	dbi

HV*
mdb_stat(txn, dbi)
	LMDB::Txn   txn
	LMDB	dbi
    PREINIT:
	MDB_stat    stat;
    CODE:
	populateStat(&RETVAL, mdb_stat(txn, dbi, &stat), &stat);
    OUTPUT:
	RETVAL

int
mdb_dbi_flags(txn, dbi, flags)
	LMDB::Txn   txn
	LMDB	dbi
	unsigned int &flags = NO_INIT
    CODE:
	RETVAL = mdb_dbi_flags(mdb_txn_env(txn), dbi, &flags);
	ProcError(RETVAL);
    OUTPUT:
	RETVAL
	flags

void
mdb_dbi_close(env, dbi)
	LMDB::Env   env
	LMDB	dbi

int
mdb_drop(txn, dbi, del)
	LMDB::Txn   txn
	LMDB	dbi
	int	del

=pod
int
mdb_set_compare(txn, dbi, cmp)
	LMDB::Txn   txn
	LMDB	dbi
	MDB_cmp_func *	cmp

int
mdb_set_dupsort(txn, dbi, cmp)
	LMDB::Txn   txn
	LMDB	dbi
	MDB_cmp_func *	cmp

int
mdb_set_relfunc(txn, dbi, rel)
	LMDB::Txn   txn
	LMDB	dbi
	MDB_rel_func *	rel

int
mdb_set_relctx(txn, dbi, ctx)
	LMDB::Txn   txn
	LMDB	dbi
	void *	ctx
=cut

int
mdb_get(txn, dbi, key, data)
	LMDB::Txn   txn
	LMDB	dbi
	DBK	&key
	DBD	&data = NO_INIT
    PREINIT:
	dMY_MULTICALL;
    INIT:
	MY_PUSH_MULTICALL(txn, dbi);
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);
    OUTPUT:
	data

int
mdb_put(txn, dbi, key, data, flags)
	LMDB::Txn   txn
	LMDB	 dbi
	DBK	&key
	DBD	&data
	flags_t	flags
    PREINIT:
	dMY_MULTICALL;
    INIT:
	if(flags & MDB_RESERVE) /* TODO */
	    croak("MDB_RESERVE flag unimplemented.");
	MY_PUSH_MULTICALL(txn, dbi);
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);

int
mdb_del(txn, dbi, key, data)
	LMDB::Txn   txn
	LMDB	dbi
	DBK	&key
	DBD	&data
    PREINIT:
	dMY_MULTICALL;
    INIT:
	MY_PUSH_MULTICALL(txn, dbi);
    CODE:
	RETVAL = mdb_del(txn, dbi, &key, (SvOK(ST(3)) ? &data : NULL));
	MY_POP_MULTICALL;
	ProcError(RETVAL);
    OUTPUT:
	RETVAL

int
mdb_cmp(txn, dbi, a, b)
	LMDB::Txn   txn
	LMDB	dbi
	DBD	&a
	DBD	&b
    PREINIT:
	dMY_MULTICALL;
    INIT:
	MY_PUSH_MULTICALL(txn, dbi);
    POSTCALL:
	MY_POP_MULTICALL;

int
mdb_dcmp(txn, dbi, a, b)
	LMDB::Txn   txn
	LMDB	dbi
	DBD	&a
	DBD	&b
    PREINIT:
	dMY_MULTICALL;
    INIT:
	MY_PUSH_MULTICALL(txn, dbi);
    POSTCALL:
	MY_POP_MULTICALL;

MODULE = LMDB_File		PACKAGE = LMDB_File	    PREFIX = mdb_

=pod
int
mdb_reader_list(env, func, ctx)
	LMDB::Env   env
	MDB_msg_func *	func
	void *	ctx
=cut

int
mdb_reader_check(env, dead)
	LMDB::Env   env
	int 	&dead
    OUTPUT:
	dead

char *
mdb_strerror(err)
	int	err

char *
mdb_version(major, minor, patch)
	int 	&major = NO_INIT
	int 	&minor = NO_INIT
	int	&patch = NO_INIT
    OUTPUT:
	major
	minor
	patch

BOOT:
    my_lasterr = gv_fetchpv("LMDB_File::last_err", 0, SVt_IV);
    my_errgv = gv_fetchpv("LMDB_File::die_on_err", 0, SVt_IV);
    my_cmpgv = gv_fetchpv("LMDB_File::_cmp_cv", GV_ADD|GV_ADDWARN, SVt_RV);
    my_dcmpgv = gv_fetchpv("LMDB_File::_dcmp_cv", GV_ADD|GV_ADDWARN, SVt_RV);

