#!perl 

use Apache::ASP;

$ARGV[0] || die("no file to parse");
$r = &Apache::ASP::CGI::init(@ARGV);
&Apache::ASP::handler($r);



