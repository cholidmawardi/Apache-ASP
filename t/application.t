use Apache::ASP;
&Apache::ASP::CGI::do_self(
#	Debug => 1
);

__END__

<% 
$t->eok(sub { $Application->Lock }, '$Application->Lock');
$t->eok($Application->{Start}, 'Application_OnStart did not run');

my $count = 0;
$Application->{count} = 0;
for(1..3) {
	$Application->{count}++;
	$count++;
	$t->eok($count == $Application->{count}, 
		'failure to increment $Application->{count}');
}

$t->eok(sub { $Application->UnLock }, '$Application->UnLock');
$t->eok($Application->SessionCount(), '$Application->SessionCount()');
$t->eok($Application->GetSession($Session->{SessionID}), '$Application->GetSession()');
%>

