use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
if(length(($session_id = $Session->SessionID())) > 16) {
	$t->ok();
} else {
	$t->not_ok("session id $session_id not long enough");
}
%>

<% 
my $count = 0;
for(1..3) {
	$Session->{count}++;
	$count++;
	if($count == $Session->{count}) {
		$t->ok();
	} else {
		$t->not_ok('failure to increment $Session->{count}');
	}
}
%>

<% $t->done; %>

