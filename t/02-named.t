#!perl
use Test::More tests => 36;
use Test::Exception;
use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);

use LMDB_File qw(:flags :cursor_op);

my $dir = tempdir('mdbtXXXX', TMPDIR => 1);
ok(-d $dir, "Created test dir $dir");
my $env = LMDB::Env->new($dir, { maxdbs => 5 });
{
    is($env->BeginTxn->OpenDB->stat->{entries}, 0, 'Empty');
}
{
    my $txn = $env->BeginTxn;
    my $mdb = $txn->OpenDB;
    ok($mdb, "Main DB Opened");
    is($mdb->stat->{entries}, 0, 'Empty');
    throws_ok {
	$txn->OpenDB('SOME');
    } qr/NOTFOUND/, 'No created yet';
    my $dbi = $txn->OpenDB('SOME', MDB_CREATE);
    ok($dbi, "CI DB Opened");
    is($mdb->stat->{entries}, 1, 'Created');
}
{
    my $txn = $env->BeginTxn;
    is($txn->OpenDB->stat->{entries}, 0, 'Empty');
    throws_ok {
	$txn->OpenDB('SOME');
    } qr/NOTFOUND/, 'No preserved';
}
{
    my $txn = $env->BeginTxn;
    # A case insensitive DB
    ok(my $dbi = $txn->OpenDB('CI', MDB_CREATE), 'CI Created');
    {
	no warnings 'once';
	$dbi->set_compare(sub { lc($LMDB_File::a) cmp lc($LMDB_File::b) });
    }
    # A Reversed key order DB
    ok(my $dbr = $dbi->open('RK', MDB_CREATE|MDB_REVERSEKEY), 'RK Created');

    my %data;
    my $c;
    foreach('A' .. 'Z') {
	$c = ord($_) - ord('A') + 1;
	my $k = $_ . chr(ord('Z')+1-$c); 
	my $v = sprintf('Datum #%d', $c);
	$data{$k} = $v;
	if($c < 4) {
	    is($dbi->put($k, $v), $v, "Put in CI $k");
	    is($dbi->stat->{entries}, $c, "Entry CI $c");
	    is($dbr->put($k, $v), $v, "Put in RK $k");
	    is($dbr->stat->{entries}, $c, "Entry RK $c");
	} else {
	    # Don't be verbose
	    $dbi->put($k, $v);
	    $dbr->put($k, $v);
	}
    }
    is($c, 26, 'All in');
    # Check data in random HASH order
    $c = 5; # Don't be verbose
    while(my($k, $v) = each %data) {
	is($dbi->get(lc $k), $v, "Get CI \L$k");
	is($dbr->get($k), $v, "Get RK $k");
	--$c or last;
    }
    my $ordkey = [ sort keys %data ];
    tie %data, $dbi;
    is_deeply( $ordkey, [ keys %data ], 'Ordered');
    untie %data;
    tie %data, $dbr;
    is_deeply( $ordkey, [ reverse keys %data ], 'Reversed' );
    untie %data;
}
END {
    unless($ENV{KEEP_TMPS}) {
        for($dir) {
            unlink glob("$_/*");
            rmdir $_;
            #warn "Removed $_\n";
        }
    }
}
