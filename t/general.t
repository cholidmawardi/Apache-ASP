use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
for(@Apache::ASP::Objects) {
	if(${$_}) {
		$t->ok;
	} else {
		$t->not_ok("object $_ not defined in ASP namespace");
	}
}
$t->done();
%>	

