use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
if(%{$Request->ServerVariables()}) {
	$t->ok();
} else {
	$t->not_ok('could not get the environment / server variables');
}
%>

<% $t->done; %>