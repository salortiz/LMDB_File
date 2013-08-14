package LMDB_File;

use 5.010001;
use strict;
use warnings;
use Carp;

require Exporter;
use AutoLoader;

our @ISA = qw(Exporter);
our @CARP_NOT = qw(LMDB::Env LMDB::Txn LMDB::Cursor LMDB_File);

our @EXPORT = qw();
our %EXPORT_TAGS = (
    envflags => [qw(MDB_FIXEDMAP MDB_NOSUBDIR MDB_NOSYNC MDB_RDONLY MDB_NOMETASYNC
	MDB_WRITEMAP MDB_MAPASYNC MDB_NOTLS)], 
    dbflags => [qw(MDB_REVERSEKEY MDB_DUPSORT MDB_INTEGERKEY MDB_DUPFIXED
	MDB_INTEGERDUP MDB_REVERSEDUP MDB_CREATE)],
    writeflags => [qw(MDB_NOOVERWRITE MDB_NODUPDATA MDB_CURRENT MDB_RESERVE
	MDB_APPEND MDB_APPENDDUP MDB_MULTIPLE)],
    cursor_op => [qw(MDB_FIRST MDB_FIRST_DUP MDB_GET_BOTH MDB_GET_BOTH_RANGE
	MDB_GET_CURRENT MDB_GET_MULTIPLE MDB_NEXT MDB_NEXT_DUP MDB_NEXT_MULTIPLE
	MDB_NEXT_NODUP MDB_PREV MDB_PREV_DUP MDB_PREV_NODUP MDB_LAST MDB_LAST_DUP
	MDB_SET MDB_SET_KEY MDB_SET_RANGE)],
    error => [qw(MDB_SUCCESS MDB_KEYEXIST MDB_NOTFOUND MDB_PAGE_NOTFOUND MDB_CORRUPTED
	MDB_PANIC MDB_VERSION_MISMATCH MDB_INVALID MDB_MAP_FULL MDB_DBS_FULL
	MDB_READERS_FULL MDB_TLS_FULL MDB_TXN_FULL MDB_CURSOR_FULL MDB_PAGE_FULL
	MDB_MAP_RESIZED MDB_INCOMPATIBLE MDB_BAD_RSLOT MDB_LAST_ERRCODE)],
    version => [qw(MDB_VERSION_FULL MDB_VERSION_MAJOR MDB_VERSION_MINOR
	MDB_VERSION_PATCH MDB_VERSION_STRING MDB_VERSION_DATE)],
    other => [qw(
	cmp
	cursor_close
	cursor_count
	cursor_dbi
	cursor_del
	cursor_get
	cursor_open
	cursor_put
	cursor_renew
	cursor_txn
	dbi_close
	dbi_flags
	dbi_open
	dcmp
	del
	drop
	env_close
	env_copy
	env_copyfd
	env_create
	env_get_flags
	env_get_maxreaders
	env_get_path
	env_info
	env_open
	env_set_flags
	env_set_mapsize
	env_set_maxdbs
	env_set_maxreaders
	env_stat
	env_sync
	get
	gnu_dev_major
	gnu_dev_makedev
	gnu_dev_minor
	pselect
	put
	reader_check
	reader_list
	select
	set_compare
	set_dupsort
	set_relctx
	set_relfunc
	stat
	strerror
	txn_abort
	txn_begin
	txn_commit
	txn_renew
	txn_reset
	version
)]);
$EXPORT_TAGS{flags} = [
    @{$EXPORT_TAGS{envflags}}, @{$EXPORT_TAGS{dbflags}}, @{$EXPORT_TAGS{writeflags}}
];
{
    my %seen;
    push @{$EXPORT_TAGS{all}},
	grep {!$seen{$_}++} @{$EXPORT_TAGS{$_}} foreach keys %EXPORT_TAGS;
}
our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our $VERSION = '0.01';
our $DEBUG = 0;

sub AUTOLOAD {
    my $constname;
    our $AUTOLOAD;
    ($constname = $AUTOLOAD) =~ s/.*:://;
    croak "&LMDB_File::constant not defined" if $constname eq 'constant';
    my ($error, $val) = constant($constname);
    if ($error) { croak $error; }
    {
	no strict 'refs';
	*$AUTOLOAD = sub { $val };
    }
    goto &$AUTOLOAD;
}

require XSLoader;
XSLoader::load('LMDB_File', $VERSION);

package LMDB::Env;
use Scalar::Util ();

our %Envs;
sub new {
    my ($proto, $path, $eflags) = @_;
    create(my $self);
    return unless $self;
    $eflags = { flags => $eflags } unless ref $eflags;
    if($eflags) {
	$eflags->{mapsize} and $self->set_mapsize($eflags->{mapsize})
	    and return;
	$eflags->{maxdbs} and $self->set_maxdbs($eflags->{maxdbs})
	    and return;
	$eflags->{maxreaders} and $self->set_max_readers($eflags->{maxreaders})
	    and return;
    }
    $self->open($path, $eflags->{flags}, $eflags->{mode} || 0600)
	and return;
    warn "Created LMDB::Env $$self\n" if $DEBUG;
    $Envs{$$self} = { Txns => [] };
    return $self;
}

sub DESTROY {
    my $self = shift;
    my $txl = $Envs{$$self}{Txns} or return;
    if(my $act = $txl->[$#$txl]) {
	warn "LMDB: Destroying an active environment, aborted $$act!\n";
	$act->abort;
	undef $Envs{$$self}{Txns};
    }
    $self->close;
    delete $Envs{$$self};
    warn "Closed LMDB::Env $$self\n" if $DEBUG;
}

sub BeginTxn{
    my $self = shift;
    $self->get_flags(my $eflags);
    my $tflags = shift || ($eflags & LMDB_File::MDB_RDONLY());
    return LMDB::Txn->new($self, $tflags);
}

package LMDB::Txn;

my %Txns;
my %Cursors;
# All LMDB Transactions are usable only in the thread that create it
sub CLONE_SKIP { 1; }

sub new {
    my ($parent, $env, $tflags) = @_;
    my $txl = $Envs{$$env}{Txns};
    Carp::croak("Transaction active, shold be subtransaction")
	if !ref($parent) && @$txl;
    _begin($env, ref($parent) && $parent, $tflags, my $self);
    return unless $self;
    $Txns{$$self}{Env} = $env;
    $Txns{$$self}{Active} = 1;
    unshift @$txl, $self;
    Scalar::Util::weaken($txl->[0]);
    warn "Created LMDB::Txn $$self in $$env\n" if $DEBUG;
    return $self;
}

sub SubTxn {
    my $self = shift;
    my $tflags = shift || 0;
    return $self->new($self->env, $tflags);
}

sub DESTROY {
    my $self = shift;
    if($Txns{$$self}{Active}) {
	warn "LMDB: Destroying an active transaction, aborting $$self...\n";
	$self->abort;
    }
}

sub _prune {
    my $self = shift;
    my $txl = $Envs{ $self->_env }{Txns};
    while(my $rel = shift @$txl) {
	delete $Cursors{$_} for keys %{ $Txns{$$rel}{Cursors} };
	delete $Txns{$$rel};
	last if $$rel == $$self;
    }
    warn "LMDB::Txn: $$self finalized\n" if $DEBUG > 1;
}

sub abort {
    my $self = shift;
    return unless $Txns{$$self}; # Ignore unless active
    $self->_abort;
    warn "LMDB::Txn $$self aborted\n" if $DEBUG;
    $self->_prune;
}

sub commit {
    my $self = shift;
    croak("Not an active transaction") unless $Txns{$$self} && $Txns{$$self}{Active};
    $self->_commit;
    warn "LMDB::Txn $$self commited\n" if $DEBUG;
    $self->_prune;
}

sub reset {
    my $self = shift;
    Carp::croak("Not an active transaction") unless $Txns{$$self};
    $self->_reset if $Txns{$$self}{Active};
    $Txns{$$self}{Active} = 0;
}

sub renew {
    my $self = shift;
    Carp::croak("Not an active transaction") unless $Txns{$$self};
    $self->_reset if $Txns{$$self}{Active};
    $self->_renew;
    $Txns{$$self}{Active} = 1;
}

my $dbflmask = do {
    no strict 'refs';
    my $f = 0;
    $f |= &{'LMDB_File::'.$_}() for @{$EXPORT_TAGS{dbflags}};
    $f;
};

sub OpenDB {
    my ($self, $name, $flags) = @_;
    Carp::croak("Not an active transaction") unless $Txns{$$self};
    $flags = { flags => ($flags || 0) } unless ref $flags;
    LMDB_File::_dbi_open($self, $name, $flags->{flags} & $dbflmask, my $dbi);
    return unless $dbi;
    warn "Opened dbi #".ord($dbi)."\n" if $DEBUG;
    return bless [ $self, $dbi ], 'LMDB_File';
}

sub env {
    my $self = shift;
    return $Txns{$$self}{Env};
}

package LMDB::Cursor;

sub new {
    my ($proto, $txn, $dbi) = @_;
    LMDB::Cursor::open($txn, $dbi, my $self);
    return unless $self;
    $Txns{$$txn}{Cursors}{$$self} = 1;
    $Cursors{$$self} = $txn;
    warn "Cursor opened for #".ord($dbi)."\n" if $DEBUG;
    return $self;
}

sub DESTROY {
    my $self = shift;
    return unless $Cursors{$$self};
    my $txnId = $self->txn;
    $self->close;
    delete $Txns{$txnId}{Cursors}{$$self};
    delete $Cursors{$$self};
}

package LMDB_File;

our $_dcmp_cv;
our $_cmp_cv;

sub DESTROY {
    my $self = shift;
}

sub _chkalive {
    my $self = shift;
    my $txn = $self->[0];
    Carp::croak("Not an active transaction")
	unless($txn && ($Txns{ $$txn } || undef($self->[0])));
    $_cmp_cv = $self->[2]; $_dcmp_cv = $self->[4];
    return $txn, $self->[1];
}

sub alive {
    my $self = shift;
    my $txn = $self->[0];
    return $txn && (($Txns{$$txn}&& ord $self->[1])||undef $self->[0]||($self->[1]=0));
}

sub flags {
    my $self = shift;
    _dbi_flags(_chkalive($self), my $flags);
    $flags;
}

sub put {
    my $self = shift;
    my ($key, $data, $flags) = @_;
    warn "put: '$key' => '$data'\n" if $DEBUG > 2;
    _put(_chkalive($self), $key, $data, $flags);
    return $data;
}

sub get {
    my $self = shift;
    my $key = shift;
    warn "get: '$key'\n" if $DEBUG > 2;
    _get(_chkalive($self), $key, my $data);
    return $data;
}

sub stat {
    my $self = shift;
    _stat(_chkalive($self));
}

sub del {
    my $self = shift;
    _del(_chkalive($self), @_);
}

sub set_dupsort {
    my $self = shift;
    my $cv = shift;
    $self->[4] = $cv;
}

sub OpenCursor {
    my $self = shift;
    return LMDB::Cursor->new(_chkalive($self));
}

our $die_on_err = 1;
our $last_err = 0;

sub TIEHASH {
    my $proto = shift;
    return $proto if ref($proto) && _chkalive($proto); # Auto
    my $mux = shift;
    return $mux->OpenDB(@_) if ref $mux eq 'LMDB::Txn';
    return $mux->BeginTxn->OpenDB(@_) if ref $mux eq 'LMDB::Env';
    my $gflags = shift;
    $gflags = { flags => $gflags } unless ref $gflags;
    $gflags->{mode} = shift if @_;
    my $env = LMDB::Env->new($mux, $gflags);
    my $dbi = $env->BeginTxn->OpenDB($gflags->{dbname}, $gflags);
    return $dbi;
}

sub FETCH {
    my($self, $key) = @_;
    my ($data, $res);
    {
	local $die_on_err = 0;
	$res = _get(_chkalive($self), $key,$data);
    }
    croak($@) if $res && $res != MDB_NOTFOUND() && $die_on_err;
    return $data;
}

*STORE = \&LMDB::put;

sub UNTIE {
    my $self = shift;
    my $txn = $self->[0];
    return unless($txn && ($Txns{ $$txn } || undef($self->[0])));
    $txn->commit;
    delete $self->[4]; # Free dcmp callback
    delete $self->[3]; # Free cursor
    delete $self->[2]; # Free cmp callback
}

sub SCALAR {
    _chkalive(my $self = shift);
    return !$self->[1]->stat->{entries};
}

sub EXISTS {
    my($self, $key) = @_;
    local $die_on_err = 0;
    return !_get(_chkalive($self), $key, my $dummy);
}

sub DELETE {
    my($self, $key) = @_;
    my @self = _chkalive($self);
    my $data;
    local $die_on_err = 0;
    if(_get(@self, $key, $data) != MDB_NOTFOUND()) {
	_del(@self, $key, undef);
    }
    return $data;
}

sub FIRSTKEY {
    my $self = shift;
    $self->[3] = LMDB::Cursor->new(_chkalive($self));
    $self->NEXTKEY;
}

sub NEXTKEY {
    my($self, $key) = @_;
    my $op = defined($key) ? MDB_NEXT() : MDB_FIRST() ;
    #warn "In NK: $op '$key'\n";
    local $die_on_err = 0;
    my $res = $self->[3]->get($key, my $data, $op);
    if($res == MDB_NOTFOUND()) {
	return;
    }
    return $key, $data;
}

# Autoload methods go after =cut, and are processed by the autosplit program.

1;
__END__

=head1 NAME

LMDB - Perl extension for OpenLDAP's Lightning Memory-Mapped Database

=head1 SYNOPSIS

  use LMDB_File;

  # Simple TIE interface
  tie %hash, 'LMDB', $path, $flags';

=head1 DESCRIPTION

LMDB_File is a module which allows Perl programs to make use of the
facilities provided by the OpenLDAP's Lightning Memory-Mapped Database "lmdb".

lmdb is a Btree-based database management library modeled loosely on the
BerkeleyDB API, but much simplified and extremely fast.

It is assumed that you have a copy of lmbd's documentation at hand when reading
this documentation. The interface defined here mirrors the C interface closely
but with an OO approach.




=head2 EXPORT

None by default.

=head2 Exportable constants

  MDB_APPEND
  MDB_APPENDDUP
  MDB_BAD_RSLOT
  MDB_CORRUPTED
  MDB_CREATE
  MDB_CURRENT
  MDB_CURSOR_FULL
  MDB_DBS_FULL
  MDB_DUPFIXED
  MDB_DUPSORT
  MDB_FIRST
  MDB_FIRST_DUP
  MDB_FIXEDMAP
  MDB_GET_BOTH
  MDB_GET_BOTH_RANGE
  MDB_GET_CURRENT
  MDB_GET_MULTIPLE
  MDB_INCOMPATIBLE
  MDB_INTEGERDUP
  MDB_INTEGERKEY
  MDB_INVALID
  MDB_KEYEXIST
  MDB_LAST
  MDB_LAST_DUP
  MDB_LAST_ERRCODE
  MDB_MAPASYNC
  MDB_MAP_FULL
  MDB_MAP_RESIZED
  MDB_MULTIPLE
  MDB_NEXT
  MDB_NEXT_DUP
  MDB_NEXT_MULTIPLE
  MDB_NEXT_NODUP
  MDB_NODUPDATA
  MDB_NOMETASYNC
  MDB_NOOVERWRITE
  MDB_NOSUBDIR
  MDB_NOSYNC
  MDB_NOTFOUND
  MDB_NOTLS
  MDB_PAGE_FULL
  MDB_PAGE_NOTFOUND
  MDB_PANIC
  MDB_PREV
  MDB_PREV_DUP
  MDB_PREV_NODUP
  MDB_RDONLY
  MDB_READERS_FULL
  MDB_RESERVE
  MDB_REVERSEDUP
  MDB_REVERSEKEY
  MDB_SET
  MDB_SET_KEY
  MDB_SET_RANGE
  MDB_SUCCESS
  MDB_TLS_FULL
  MDB_TXN_FULL
  MDB_VERSION_FULL
  MDB_VERSION_MAJOR
  MDB_VERSION_MINOR
  MDB_VERSION_MISMATCH
  MDB_VERSION_PATCH
  MDB_VERSION_STRING
  MDB_WRITEMAP

=head2 Exportable functions

  int mdb_cmp(MDB_txn *txn, MDB_dbi dbi, const MDB_val *a, const MDB_val *b)
  void mdb_cursor_close(MDB_cursor *cursor)
  int mdb_cursor_count(MDB_cursor *cursor, size_t *countp)
  MDB_dbi mdb_cursor_dbi(MDB_cursor *cursor)
  int mdb_cursor_del(MDB_cursor *cursor, unsigned int flags)
  int mdb_cursor_get(MDB_cursor *cursor, MDB_val *key, MDB_val *data,
       MDB_cursor_op op)
  int mdb_cursor_open(MDB_txn *txn, MDB_dbi dbi, MDB_cursor **cursor)
  int mdb_cursor_put(MDB_cursor *cursor, MDB_val *key, MDB_val *data,
    unsigned int flags)
  int mdb_cursor_renew(MDB_txn *txn, MDB_cursor *cursor)
  MDB_txn *mdb_cursor_txn(MDB_cursor *cursor)
  void mdb_dbi_close(MDB_env *env, MDB_dbi dbi)
  int mdb_dbi_flags(MDB_env *env, MDB_dbi dbi, unsigned int *flags)
  int mdb_dbi_open(MDB_txn *txn, const char *name, unsigned int flags, MDB_dbi *dbi)
  int mdb_dcmp(MDB_txn *txn, MDB_dbi dbi, const MDB_val *a, const MDB_val *b)
  int mdb_del(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data)
  int mdb_drop(MDB_txn *txn, MDB_dbi dbi, int del)
  void mdb_env_close(MDB_env *env)
  int mdb_env_copy(MDB_env *env, const char *path)
  int mdb_env_copyfd(MDB_env *env, mdb_filehandle_t fd)
  int mdb_env_create(MDB_env **env)
  int mdb_env_get_flags(MDB_env *env, unsigned int *flags)
  int mdb_env_get_maxreaders(MDB_env *env, unsigned int *readers)
  int mdb_env_get_path(MDB_env *env, const char **path)
  int mdb_env_info(MDB_env *env, MDB_envinfo *stat)
  int mdb_env_open(MDB_env *env, const char *path, unsigned int flags, mdb_mode_t mode)
  int mdb_env_set_flags(MDB_env *env, unsigned int flags, int onoff)
  int mdb_env_set_mapsize(MDB_env *env, size_t size)
  int mdb_env_set_maxdbs(MDB_env *env, MDB_dbi dbs)
  int mdb_env_set_maxreaders(MDB_env *env, unsigned int readers)
  int mdb_env_stat(MDB_env *env, MDB_stat *stat)
  int mdb_env_sync(MDB_env *env, int force)
  int mdb_get(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data)
  int mdb_put(MDB_txn *txn, MDB_dbi dbi, MDB_val *key, MDB_val *data,
       unsigned int flags)
  int mdb_reader_check(MDB_env *env, int *dead)
  int mdb_reader_list(MDB_env *env, MDB_msg_func *func, void *ctx)
  int mdb_set_compare(MDB_txn *txn, MDB_dbi dbi, MDB_cmp_func *cmp)
  int mdb_set_dupsort(MDB_txn *txn, MDB_dbi dbi, MDB_cmp_func *cmp)
  int mdb_set_relctx(MDB_txn *txn, MDB_dbi dbi, void *ctx)
  int mdb_set_relfunc(MDB_txn *txn, MDB_dbi dbi, MDB_rel_func *rel)
  int mdb_stat(MDB_txn *txn, MDB_dbi dbi, MDB_stat *stat)
  char *mdb_strerror(int err)
  void mdb_txn_abort(MDB_txn *txn)
  int mdb_txn_begin(MDB_env *env, MDB_txn *parent, unsigned int flags, MDB_txn **txn)
  int mdb_txn_commit(MDB_txn *txn)
  int mdb_txn_renew(MDB_txn *txn)
  void mdb_txn_reset(MDB_txn *txn)
  char *mdb_version(int *major, int *minor, int *patch)



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

Salvador Ortiz Garcia, E<lt>sortiz@cpam.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Salvador Ortiz Garcia

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
