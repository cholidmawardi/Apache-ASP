use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<%
# normal shape of include command
if('<!--#include file="include.inc"-->' =~ /^1/) {
	$t->ok();
} else {
	$t->not_ok;
}

# should parse both in at once
if('<!--#include file="include.inc"-->' =~ /^1/) {
	$t->ok();
} else {
	$t->not_ok;
}

#abnormal possible use of include command
if(	
	'<!--#include 
		file = "include.inc"
		-->' =~ /^1/) {
	$t->ok();
} else {
	$t->not_ok;
}

my $trapped = $Response->TrapInclude('include.inc');
$t->eok($$trapped eq '1', '$Response->TrapInclude()');

$Response->Include('include.inc');
my $ref = $Response->{BinaryRef};
$t->eok($$ref =~ /1/, '$Response->Include()');
$$ref =~ s/1//isg;

$t->done;
%>

