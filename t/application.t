use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
my $count = 0;
$Application->{count} = 0;
for(1..3) {
	$Application->{count}++;
	$count++;
	if($count == $Application->{count}) {
		$t->ok();
	} else {
		$t->not_ok('failure to increment $Application->{count}');
	}
}
%>

<% $t->done; %>
