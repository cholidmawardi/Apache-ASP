use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>
<% 
eval { my $Params = $Request->Params(); };
$t->eok($@ && ( $@ =~ /Request.*Params does not exist/i ), "Error message for NULL \$Request->Params");
%>
<% $t->done; %>
