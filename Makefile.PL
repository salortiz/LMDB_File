use 5.010000;
use strict;
use ExtUtils::MakeMaker;
use Config;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

my $LNAME = 'LMDB';
my $NAME = "${LNAME}_File";
my ($LIBS) = map { /^LIBS=(.*)$/ && $1 || () } @ARGV;
my ($INC) = map { /^INC=(.*)/ && $1 || () } @ARGV;
my $myextlib = '';
{
    $LIBS ||= '';
    my @libdata = ExtUtils::Liblist->ext($LIBS || '-llmdb', 0, 'mdb_env_create');
    my @stdinc = qw(/usr/include /usr/local/include);
    push @stdinc, $libdata[3] if $libdata[3];
    my($Head) = grep -f "$_/lmdb.h", @stdinc;
    if(($INC || $Head) && $libdata[0]) {
	$INC ||= "-I$Head" if -f "$libdata[3]/lmdb.h";
	warn "Will use SYSTEM lmdb in $libdata[3]\n";
	$LIBS ||= '-llmdb';
	warn "If that path isn't a standard one, you may need to set LD_LIBRARY_PATH!\n"
	    if($libdata[4][0] =~ /.so/);
    } else {
	warn "Will use my own copy of liblmdb.\n";
	$myextlib = 'liblmdb/liblmdb$(LIB_EXT)';
    }

    #LMDB needs pthreads, perl can provide it, but...
    $LIBS .= ' -lpthread' unless $Config{useithreads} eq 'define';
    $LIBS .= ' -lrt' if $^O =~ /solaris/i;
}

WriteMakefile(
    NAME		=> $NAME,
    MIN_PERL_VERSION	=> '5.10.0',
    VERSION_FROM	=> "lib/$NAME.pm", # finds $VERSION
    PREREQ_PM		=> {}, # e.g., Module::Name => 1.1
    ABSTRACT_FROM	=> "lib/$NAME.pm", # retrieve abstract from module
    AUTHOR		=> 'Salvador Ortiz <sog@msg.com.mx>',
    DEFINE		=> '', # e.g., '-DHAVE_SOMETHING'
    XSPROTOARG		=> '-noprototypes',
    LICENSE		=> 'artistic_2',
    TEST_REQUIRES	=> { 'Test::More' => 0, 'Test::Exception' => 0 },
    OBJECT		=> '$(O_FILES)', # link all the C files too
    LIBS		=> $LIBS,
    ($myextlib ? (
	MYEXTLIB	=> $myextlib,
	INC		=> '-I./liblmdb',
	) : (
	INC		=> $INC
	)
    ),
);
if  (eval {require ExtUtils::Constant; 1}) {
  # If you edit these definitions to change the constants used by this module,
  # you will need to use the generated const-c.inc and const-xs.inc
  # files to replace their "fallback" counterparts before distributing your
  # changes.
  my @names = (qw(MDB_APPEND MDB_APPENDDUP MDB_BAD_RSLOT MDB_CORRUPTED
		 MDB_CREATE MDB_CURRENT MDB_CURSOR_FULL MDB_DBS_FULL
		 MDB_DUPFIXED MDB_DUPSORT MDB_FIXEDMAP MDB_INCOMPATIBLE
		 MDB_INTEGERDUP MDB_INTEGERKEY MDB_INVALID MDB_KEYEXIST
		 MDB_LAST_ERRCODE MDB_MAPASYNC MDB_MAP_FULL MDB_MAP_RESIZED
		 MDB_MULTIPLE MDB_NODUPDATA MDB_NOLOCK MDB_NOMEMINIT
		 MDB_NOMETASYNC MDB_NOOVERWRITE MDB_NORDAHEAD
		 MDB_NOSUBDIR MDB_NOSYNC MDB_NOTFOUND MDB_NOTLS MDB_PAGE_FULL
		 MDB_PAGE_NOTFOUND MDB_PANIC MDB_RDONLY MDB_READERS_FULL
		 MDB_RESERVE MDB_REVERSEDUP MDB_REVERSEKEY MDB_SUCCESS
		 MDB_TLS_FULL MDB_TXN_FULL MDB_VERSION_FULL MDB_VERSION_MAJOR
		 MDB_VERSION_MINOR MDB_VERSION_MISMATCH MDB_VERSION_PATCH
		 MDB_WRITEMAP),
	      {name=>"MDB_VERSION_STRING", type=>"PV", macro=>"1"},
	      {name=>"MDB_VERSION_DATE", type=>"PV", macro=>"1"},
              {name=>"MDB_FIRST", macro=>"1"},
              {name=>"MDB_FIRST_DUP", macro=>"1"},
              {name=>"MDB_GET_BOTH", macro=>"1"},
              {name=>"MDB_GET_BOTH_RANGE", macro=>"1"},
              {name=>"MDB_GET_CURRENT", macro=>"1"},
              {name=>"MDB_GET_MULTIPLE", macro=>"1"},
              {name=>"MDB_LAST", macro=>"1"},
              {name=>"MDB_LAST_DUP", macro=>"1"},
              {name=>"MDB_NEXT", macro=>"1"},
              {name=>"MDB_NEXT_DUP", macro=>"1"},
              {name=>"MDB_NEXT_MULTIPLE", macro=>"1"},
              {name=>"MDB_NEXT_NODUP", macro=>"1"},
              {name=>"MDB_PREV", macro=>"1"},
              {name=>"MDB_PREV_DUP", macro=>"1"},
              {name=>"MDB_PREV_NODUP", macro=>"1"},
              {name=>"MDB_SET", macro=>"1"},
              {name=>"MDB_SET_KEY", macro=>"1"},
              {name=>"MDB_SET_RANGE", macro=>"1"});
  ExtUtils::Constant::WriteConstants(
                                     NAME         => $NAME,
                                     NAMES        => \@names,
                                     DEFAULT_TYPE => 'IV',
                                     C_FILE       => 'const-c.inc',
                                     XS_FILE      => 'const-xs.inc',
                                  );

}
else {
  use File::Copy;
  use File::Spec;
  foreach my $file ('const-c.inc', 'const-xs.inc') {
    my $fallback = File::Spec->catfile('fallback', $file);
    copy ($fallback, $file) or die "Can't copy $fallback to $file: $!";
  }
}

sub MY::postamble {
    if($myextlib) {
	if ($^O =~ /MSWin32/ && !defined($ENV{SYSTEMROOT})) {
	    if ($Config{'make'} =~ /dmake/i) {
		return <<'EOT';
$(MYEXTLIB): liblmdb/Makefile
@[
	cd liblmdb
	$(MAKE) liblmdb$(LIB_EXT)
	cd ..
]
EOT
	    } elsif ($Config{'make'} =~ /nmake/i) {
		return <<'EOT';
$(MYEXTLIB): liblmdb/Makefile
	cd liblmdb
	$(MAKE) liblmdb$(LIB_EXT)
	cd ..
EOT
	    } 
	} else {
	    return <<'EOT';
$(MYEXTLIB): liblmdb/Makefile
	cd liblmdb && $(MAKE) liblmdb$(LIB_EXT)
EOT
	}
    }
}
