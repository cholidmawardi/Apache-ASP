#!perl

$necessary_modules = {
    'Apache' => 'Make sure your installation of mod_perl is complete',
    'MLDBM' => 'This is used for reading and writing multi-level hashes on disk',
    'SDBM_File' => 'Internal databases used for state files, like $Session',
    'Data::Dumper' => 'Serializes data for MLDBM',
    'File::stat' => 'Nice way of checking modification times for files',
    'File::Basename' => 'Nice way of parsing directory and file paths',
    'Fcntl' => 'Used for file locking constants',
    'MD5' => '32 byte hash algorithm for cookie session-id',
    'HTTP::Date' => 'Provides mapping between Perl time() and HTTP dates',
    'Carp' => 'Provides critical error messaging with confess()',
};

$optional_modules = {
    'Devel::Symdump' => 'Used for StatINC setting, which reloads modules dynamically',
    'Win32::OLE' => { 
	test => '$^O eq \'MSWin32\'',
	message => 'Required for access to ActiveX objects on Win32, like ADO.',
    },
    'CGI' => 'Required for file upload, make test, and command line ./cgi/asp script',
    'DB_File' => 'Optional module for StateDB config option'
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
    my $data = $optional_modules->{$_};
    my $message = ref($data) ? $data->{message} : $data;

    # if there is a test for this module run it and if returns false
    # skip this module's message, first so UNIX users don't see 
    # message about Win32::OLE
    if(ref($data) && $data->{test} && ! eval($data->{test})) {
	next;
    }

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

