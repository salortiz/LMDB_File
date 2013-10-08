#define PERL_NO_GET_CONTEXT
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

typedef IV MyInt;

#define StoreUV(k, v)	hv_store(RETVAL, (k), strlen(k), newSVuv(v), 0)

static void
populateStat(pTHX_ HV** hashptr, int res, MDB_stat *stat)
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
typedef	MDB_txn*    LMDB__Txn;
typedef	MDB_txn*    TxnOrNull;
typedef	MDB_dbi	    LMDB;
typedef	MDB_val	    DBD;
typedef	MDB_val	    DBK;
typedef	MDB_val	    DBKC;
typedef	MDB_cursor* LMDB__Cursor;
typedef	unsigned int flags_t;

static GV *my_lasterr;
static GV *my_errgv;
#define DieOnErr    SvTRUE(GvSV(my_errgv))

#define MY_CXT_KEY  "LMDB_File::_guts" XS_VERSION
typedef struct {
    AV *currdb;
    unsigned int cflags;
    SV *my_asv;
    SV *my_bsv;
    OP *lmdb_dcmp_cop;
} my_cxt_t;

START_MY_CXT

#define MY_CMP	    *av_fetch(MY_CXT.currdb, 2, 1)
#define MY_DCMP	    *av_fetch(MY_CXT.currdb, 3, 1)
#define FAST_MODE   SvTRUE(*av_fetch(MY_CXT.currdb, 5, 1))
#define PRED_FLGS   mdb_dbi_flags(txn, dbi, &MY_CXT.cflags)
#define dCURSOR	    MDB_txn* txn; MDB_dbi dbi
#define PREC_FLGS(c) txn = mdb_cursor_txn(c); dbi = mdb_cursor_dbi(c); PRED_FLGS
#define ISDBKINT    F_ISSET(MY_CXT.cflags, MDB_INTEGERKEY)
#define ISDBDINT    F_ISSET(MY_CXT.cflags, MDB_DUPSORT|MDB_INTEGERDUP)

static void
sv_setstatic(pTHX_ SV *const sv, MDB_val *data)
{
    dMY_CXT;
    if(ISDBDINT)
	    sv_setiv_mg(sv, *(MyInt *)data->mv_data);
    else {
	if(FAST_MODE) {
	    SV_CHECK_THINKFIRST_COW_DROP(sv);
	    SvUPGRADE(sv, SVt_PV);
	    if (SvPVX_const(sv))
		SvPV_free(sv);

	    SvCUR_set(sv, data->mv_size);
	    SvPV_set(sv, data->mv_data);
	    SvLEN_set(sv, 0); /* Tell Perl not to free memory */
	    SvPOK_only(sv);
	    SvREADONLY_on(sv);
	} else {
	    sv_setpvn_mg(sv, data->mv_data, data->mv_size);
	    SvUTF8_off(sv);
	}
    }
}

/* Callback handling */

static int
LMDB_cmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    dMY_CXT;
    dSP;
    int ret;
    ENTER; SAVETMPS;
    PUSHMARK(SP);
    sv_setpvn_mg(MY_CXT.my_asv, a->mv_data, a->mv_size);
    sv_setpvn_mg(MY_CXT.my_bsv, b->mv_data, b->mv_size);
    call_sv(SvRV(MY_CMP), G_SCALAR|G_NOARGS);
    SPAGAIN;
    ret = POPi;
    PUTBACK;
    FREETMPS; LEAVE;
    return ret;
}

#define dMCOMMON        \
    dMY_CXT;	         \
    int needsave = 0;	  \
    SV *my_cmpsv = MY_CMP; \
    SV *my_dcmpsv = MY_DCMP

#define MY_PUSH_COMMON \
    if(SvROK(my_cmpsv) && SvTYPE(SvRV(my_cmpsv)) == SVt_PVCV) {	    \
	mdb_set_compare(txn, dbi, LMDB_cmp);			    \
	needsave++;						    \
    }								    \
    if(needsave) {						    \
	SAVESPTR(MY_CXT.my_asv);				    \
	SAVESPTR(MY_CXT.my_bsv);				    \
    }

#ifdef dMULTICALL
/* If this perl has MULTICALL support, use it for the DATA comparer */
static int
LMDB_dcmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    dMY_CXT;
    sv_setpvn_mg(MY_CXT.my_asv, a->mv_data, a->mv_size);
    sv_setpvn_mg(MY_CXT.my_bsv, b->mv_data, b->mv_size);
    PL_op = MY_CXT.lmdb_dcmp_cop;
    CALLRUNOPS(aTHX);
    return SvIV(*PL_stack_sp);
}

#define dMY_MULTICALL \
    dMCOMMON;          \
    dMULTICALL;         \
    I32 gimme = G_SCALAR

#define MY_PUSH_MULTICALL \
    multicall_cv = NULL;   \
    if(SvROK(my_dcmpsv) && SvTYPE(SvRV(my_dcmpsv)) == SVt_PVCV) {   \
	PUSH_MULTICALL((CV *)SvRV(my_dcmpsv));			    \
	MY_CXT.lmdb_dcmp_cop = multicall_cop;			    \
	mdb_set_dupsort(txn, dbi, LMDB_dcmp);			    \
	needsave++;						    \
    }								    \
    MY_PUSH_COMMON

#define MY_POP_MULTICALL    \
    if(multicall_cv) {            \
	POP_MULTICALL; newsp = newsp;  \
    }

#else /* NO MULTICALL support, use a slow path */

static int
LMDB_dcmp(const MDB_val *a, const MDB_val *b) {
    dTHX;
    dMY_CXT;
    dSP;
    int ret;
    ENTER; SAVETMPS;
    PUSHMARK(SP);
    sv_setpvn_mg(MY_CXT.my_asv, a->mv_data, a->mv_size);
    sv_setpvn_mg(MY_CXT.my_bsv, b->mv_data, b->mv_size);
    call_sv(SvRV(MY_DCMP), G_SCALAR|G_NOARGS);
    SPAGAIN;
    ret = POPi;
    PUTBACK;
    FREETMPS; LEAVE;
    return ret;
}

#define dMY_MULTICALL  dMCOMMON

#define MY_PUSH_MULTICALL \
    if(SvROK(my_dcmpsv) && SvTYPE(SvRV(my_dcmpsv)) == SVt_PVCV) {   \
	mdb_set_dupsort(tx, dbi, LMDB_dcmp);			    \
	needsave++;						    \
    }								    \
    MY_PUSH_COMMON

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
	populateStat(aTHX_ &RETVAL, mdb_env_stat(env, &stat), &stat);
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
mdb_env_sync(env, force=0)
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
	flags_t	    flags
	LMDB::Txn   &txn = NO_INIT
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

int
mdb_cursor_open(txn, dbi, cursor)
	LMDB::Txn   txn
	LMDB	dbi
	LMDB::Cursor	&cursor = NO_INIT
    OUTPUT:
	cursor

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
	flags_t		flags

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

MODULE = LMDB_File	PACKAGE = LMDB::Cursor	PREFIX = mdb_cursor

int
mdb_cursor_get(cursor, key, data, op)
    PREINIT:
	dMY_MULTICALL;
	dCURSOR;
    INPUT:
	LMDB::Cursor	cursor + PREC_FLGS($var);
	DBKC	&key	
	DBD	&data
	MDB_cursor_op	op
    INIT:
	MY_PUSH_MULTICALL;
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);
    OUTPUT:
	key
	data

int
mdb_cursor_put(cursor, key, data, flags)
    PREINIT:
	dMY_MULTICALL;
	dCURSOR;
    INPUT:
	LMDB::Cursor	cursor + PREC_FLGS($var);
	DBKC	&key
	DBD	&data
	flags_t	flags
    INIT:
	MY_PUSH_MULTICALL;
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);

MODULE = LMDB_File		PACKAGE = LMDB_File	    PREFIX = mdb

#ifdef __GNUC__
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif

INCLUDE: const-xs.inc

#ifdef __GNUC__
#pragma GCC diagnostic warning "-Wmaybe-uninitialized"
#endif

void
_setcurrent(currdb)
	AV* currdb
    PREINIT:
	dMY_CXT;
    CODE:
	MY_CXT.currdb = currdb;

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
	populateStat(aTHX_ &RETVAL, mdb_stat(txn, dbi, &stat), &stat);
    OUTPUT:
	RETVAL

int
mdb_dbi_flags(txn, dbi, flags)
	LMDB::Txn   txn
	LMDB	dbi
	unsigned int &flags = NO_INIT
    POSTCALL:
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
    PREINIT:
	dMY_MULTICALL;
    INPUT:
	LMDB::Txn   txn + PRED_FLGS;
	LMDB	dbi
	DBK	&key
	DBD	&data = NO_INIT
    INIT:
	MY_PUSH_MULTICALL;
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);
    OUTPUT:
	data

int
mdb_put(txn, dbi, key, data, flags)
    PREINIT:
	dMY_MULTICALL;
    INPUT:
	LMDB::Txn   txn + PRED_FLGS;
	LMDB	 dbi
	DBK	&key
	DBD	&data
	flags_t	flags
    INIT:
	if(flags & MDB_RESERVE) /* TODO */
	    croak("MDB_RESERVE flag unimplemented.");
	MY_PUSH_MULTICALL;
    POSTCALL:
	MY_POP_MULTICALL;
	ProcError(RETVAL);

int
mdb_del(txn, dbi, key, data)
    PREINIT:
	dMY_MULTICALL;
    INPUT:
	LMDB::Txn   txn + PRED_FLGS;
	LMDB	dbi
	DBK	&key
	DBD	&data
    INIT:
	MY_PUSH_MULTICALL;
    CODE:
	RETVAL = mdb_del(txn, dbi, &key, (SvOK(ST(3)) ? &data : NULL));
	MY_POP_MULTICALL;
	ProcError(RETVAL);
    OUTPUT:
	RETVAL

int
mdb_cmp(txn, dbi, a, b)
    PREINIT:
	dMY_MULTICALL;
    INPUT:
	LMDB::Txn   txn + PRED_FLGS;
	LMDB	dbi
	DBD	&a
	DBD	&b
    INIT:
	MY_PUSH_MULTICALL;
    POSTCALL:
	MY_POP_MULTICALL;

int
mdb_dcmp(txn, dbi, a, b)
    PREINIT:
	dMY_MULTICALL;
    INPUT:
	LMDB::Txn   txn + PRED_FLGS;
	LMDB	dbi
	DBD	&a
	DBD	&b
    INIT:
	MY_PUSH_MULTICALL;
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
    MY_CXT_INIT;
    MY_CXT.my_asv = get_sv("::a", GV_ADDMULTI);	    
    MY_CXT.my_bsv = get_sv("::b", GV_ADDMULTI);	    
    my_lasterr = gv_fetchpv("LMDB_File::last_err", 0, SVt_IV);
    my_errgv = gv_fetchpv("LMDB_File::die_on_err", 0, SVt_IV);

