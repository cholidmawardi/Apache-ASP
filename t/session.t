use Apache::ASP;
&Apache::ASP::CGI::do_self(
#	Debug => 1
);

__END__

<% 
$t->eok(sub { $Session->Lock() }, '$Session->Lock');
$t->eok(length($Session->{SessionID}) >= 8, "session id not long enough");
my $count = 0;
for(1..3) {
	$Session->{count}++;
	$count++;
	$t->eok($count == $Session->{count}, 
		'failure to increment $Session->{count}');
}
$t->eok(sub { $Session->UnLock() }, '$Session->UnLock');
%>


