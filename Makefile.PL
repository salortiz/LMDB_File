use 5.010001;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'LMDB_File',
    VERSION_FROM      => 'lib/LMDB_File.pm', # finds $VERSION
    PREREQ_PM         => {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/LMDB_File.pm', # retrieve abstract from module
       AUTHOR         => 'Salvador Ortiz Garcia <sog@msg.com.mx>') : ()),
    LIBS              => ['-llmdb '], # e.g., '-lm'
    DEFINE            => '', # e.g., '-DHAVE_SOMETHING'
    INC               => '-I.', # e.g., '-I. -I/usr/include/other'
	# Un-comment this if you add C files to link with later:
     OBJECT            => '$(O_FILES)', # link all the C files too
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
		 MDB_MULTIPLE MDB_NODUPDATA MDB_NOMETASYNC MDB_NOOVERWRITE
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
                                     NAME         => 'LMDB',
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
