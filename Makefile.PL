#!perl

@mods = (
	 'Apache', 
	 'MLDBM',
	 'SDBM_File',
	 'Data::Dumper',
	 'File::stat',
	 'File::Basename',
	 'FileHandle',
	 'Fcntl',
	 'MD5'
	 );

print "Checking for the prerequisite modules...\n";
my($errors);
for(@mods) {
    eval 'require ' . $_ ;
    if($@) {
	$errors++;
	print " ... you need the module: $_\n";
    } else {
	print " ... found $_ !\n";
    }
}

if($errors) {
    print "Exiting now because of errors!\n\n";
    exit;
} else {
    print "Looks good!\n";
}

$VERSION_FROM = 'CHANGES';
use ExtUtils::MakeMaker;
&WriteMakefile( NAME => "Apache::ASP" );

