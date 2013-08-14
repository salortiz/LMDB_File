#!perl
use Test::More tests => 100;
use Test::Exception;
use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);

use LMDB_File qw(:envflags :cursor_op);

my $dir = tempdir('mdbtXXXX', TMPDIR => 1):
ok(-d $dir, "Created test dir $dir");
{
    my $env = LMDB::Env->new($dir, { maxdbs => 5 });
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
