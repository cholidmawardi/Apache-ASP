package Bundle::Apache::ASP;

$VERSION = '1.04';

1;

__END__

=head1 NAME

Bundle::Apache::ASP - Install Apache::ASP and related modules

=head1 SYNOPSIS

 perl -MCPAN -e 'install Bundle::Apache::ASP'

=head1 CONTENTS

MLDBM		  - This is used for reading and writing multi-level hashes on disk

Data::Dumper	  - Serializes data for MLDBM

Digest::MD5	  - 32 byte hash algorithm for cookie session-id

CGI		  - Required for file upload, make test, and command line ./cgi/asp script

HTML::Clean	  - Compress text/html with Clean config or $Response->{Clean} set to 1-9

Net::SMTP	  - Runtime errors can be mailed to the webmaster with MailErrorTo config

HTTP::Date	  - Provides mapping between Perl time() and HTTP dates

Devel::Symdump	  - Used for StatINC setting, which reloads modules dynamically

Apache::DBI	  - Cache database connections per process

Compress::Zlib    - Gzip compress HTML output on the fly

Tie::Cache        - XLSTCacheSize, XSLT caching support

Time::HiRes       - Sub second timing of execution with Debug 3 enabled

HTML::Parser      - Required for HTML::FillInForm

HTML::FillInForm  - FormFill functionality which autofills HTML forms from form data

Apache::ASP	  - A perl ASP port to Apache

=head1 DESCRIPTION

This bundle contains modules used by Apache::ASP.

=head1 AUTHOR

Joshua Chamas

