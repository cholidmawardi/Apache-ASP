use Apache::ASP;
&Apache::ASP::CGI::do_self(NoState => 1);

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
   # IsClientConnected Tests
   $t->eok($Response->{IsClientConnected}, "\$Response->{IsClientConnected}");
   $t->eok($Response->IsClientConnected, "\$Response->IsClientConnected");
   $Server->{asp}{r}->connection->aborted(1);
   $Response->Flush; # updates {IsClientConnected}
   $t->eok(! $Response->{IsClientConnected}, "\$Response->{IsClientConnected} after aborted/Flush()");
   $t->eok(! $Response->IsClientConnected, "\$Response->IsClientConnected after aborted");

   # reset
   $Server->{asp}{r}->connection->aborted(0);
   $Response->{IsClientConnected} = 1;
   $t->eok($Response->IsClientConnected, "\$Response->IsClientConnected after reset");

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


