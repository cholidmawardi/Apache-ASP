use Apache::ASP;

&Apache::ASP::CGI::do_self(NoState => 1, 
			   Debug => 3, 
			   # defaults to localhost for mail relay
			   # but will lookup in Net::Config too for
			   # other hosts
			   MailHost => '127.0.0.1'
			   );

__END__

<% use lib '.';	use T;	$t =T->new(); %>
<% 

# test for Net::SMTP, and skip if not installed
eval "use Net::SMTP";
if($@) {
   $t->done;
   $Response->End;
};

$t->eok($Server->Mail({ 
			# won't actually send the mail in test mode
			Test => 1,
			To => "INVALID_USER\@apache-asp.org",
			# no from, since some mail gateways may not relay * addresses
			# so we allow for From not to be set while Test is set
			# From => "INSTALL_TEST\@apache-asp.org",
			Subject => "Test Email",
			Body => "Test Body",
			Debug => 0
			}),
	"\$Server->Mail() failed in test mode, check that your ".
	"Net::SMTP was installed with appropriate defaults."
	);
%>									
<% $t->done; %>
