#!perl

$necessary_modules = {
    'Apache' => 'Make sure your installation of mod_perl is complete',
    'MLDBM' => 'This is used for reading and writing multi-level hashes on disk',
    'SDBM_File' => 'Internal databases used for state files, like $Session',
    'Data::Dumper' => 'Serializes data for MLDBM',
    'Fcntl' => 'Used for file locking constants',
    'MD5' => '32 byte hash algorithm for cookie session-id',
    'HTTP::Date' => 'Provides mapping between Perl time() and HTTP dates',
    'Carp' => 'Provides critical error messaging with confess()',
};

$optional_modules = 
  {
   'Devel::Symdump' => 'Used for StatINC setting, which reloads modules dynamically',
   'Win32::OLE' => { 
		    test => '$^O eq \'MSWin32\'',
		    message => 'Required for access to ActiveX objects on Win32, like ADO.',
		   },
   'CGI' => 'Required for file upload, make test, and command line ./cgi/asp script',
   'Compress::Zlib' => "Required for html gzip text compression for browsers that support it",
   'DB_File' => 'Optional module for StateDB config option',
   'HTML::Clean' => 'Compress text/html with Clean config or $Response->{Clean} set to 1-9',
   'Apache::Filter' => 'Full SSI support via Apache::Filter & Apache::SSI',
   'Apache::SSI' => 'Full SSI support via Apache::Filter & Apache::SSI',
   'Net::SMTP' => 'Runtime errors can be mailed to the webmaster with MailErrorTo config',
   'Net::Config' => 'Config options for use with Net::SMTP',	     
   'XML::XSLT' => 'XSLT transformations require this module.  Install Bundle::XML from CPAN before installing this module for the first time.',
   'Tie::Cache' => 'XSLTCacheSize setting support',
   'Time::HiRes' => 'Sub second Apache::ASP response timing with Debug turned on.',
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

print "\nChecking for the optional modules...\n";
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

$CPAN = <<CPAN;

=-=-= CPAN HELP

There are many modules that have to be installed in order
to begin using Apache::ASP.  The easiest way to install
modules is with CPAN.pm.  To use its command line shell,
execute the following:

> perl -MCPAN -eshell

Then to install any modules, like HTTP::Date

> install HTTP::Date

and cpan will do all the work for you.  For more 
information, please view the CPAN docs with 

> perldoc CPAN

=-=-=

CPAN
  ;

if($errors) {
    print "\n";
    print "Exiting now because of errors!\n";
    print $CPAN;
    print "\n";
    exit;
} elsif($warnings) {
    print $CPAN;
} 

print "Looks good!\n\n";

$VERSION_FROM = 'CHANGES';
use ExtUtils::MakeMaker;
&WriteMakefile( NAME => "Apache::ASP" );

