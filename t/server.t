use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
my $encode = $Server->URLEncode("test data");
if($encode eq 'test%20data') {
	$t->ok();
} else {
	$t->not_ok('URLEncode not working');
}
%>

<% $t->done; %>