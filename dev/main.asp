<%
use strict;
&main;
sub main {
	$Response->Write("1.".__PACKAGE__.'<br>'.$main::counter++);
}
%>
