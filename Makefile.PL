#!perl

$necessary_modules = {
    'Apache' => 'Make sure your installation of mod_perl is complete',
    'MLDBM' => 'This is used reading and writing multi-level hashes on disk',
    'SDBM_File' => 'Internal databases used for state files',
    'Data::Dumper' => 'Serializes data for MLDBM',
    'File::stat' => 'Nice way of checking modification times for files',
    'File::Basename' => 'Nice way of parsing directory and file paths',
    'FileHandle' => 'Nice object interface to file handles',
    'Fcntl' => 'Used for file locking constants',
    'MD5' => '32 byte hash algorithm for cookie session-id',
    'HTTP::Date' => 'Provides mapping between Perl time() and HTTP dates',
};

$optional_modules = {
    'Devel::Symdump' => 'Used for StatINC setting, which reloads modules dynamically',
    'Win32::OLE' => 'Required for access to ActiveX objects on Win32, like ADO.',
};
	    
print "Checking for the prerequisite modules...\n";
my($errors, $warnings);
for(sort keys %$necessary_modules) {
    eval 'require ' . $_ ;
    if($@) {
	$errors++;
	print " !!! you need the module: $_\n";
	print "     WHY: $necessary_modules->{$_}\n";
    } else {
	print " ... found $_ !\n";
    }
}

for(sort keys %$optional_modules) {
    eval 'require ' . $_ ;
    if($@) {
	$warnings++;
	print " ??? you may want module: $_\n";
	print "     WHY: $optional_modules->{$_}\n";
    } else {
	print " ... found $_ !\n";
    }
}

if($errors) {
    print "\n";
    print "If you need a module, please download and install it from CPAN.\n";
    print "Exiting now because of errors!\n";
    print "\n";
    exit;
} else {
    print "Looks good!\n";
}

$VERSION_FROM = 'CHANGES';
use ExtUtils::MakeMaker;
&WriteMakefile( NAME => "Apache::ASP" );

