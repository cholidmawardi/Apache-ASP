use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
	$t->{t} += 3; 
	$t->done;
%>

ok
ok
<% 
	print "ok\n";
%>

