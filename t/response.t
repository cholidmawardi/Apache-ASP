use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
	$t->{t} += 3; 
	$t->done;
	$Response->Write("");
%>

ok
ok
<% 
	print "ok\n";
#	$Response->AppendToLog("logging ok");
#	$Response->Debug("logging ok");
%>


