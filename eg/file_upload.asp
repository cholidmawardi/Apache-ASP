<!--#include file="header.inc"-->

This example shows you how to Apache::ASP to handle file uploads.
You need to have a recent version CGI.pm to use this facility.
Just click Browse..., select your file, hit 'file upload' and 
voila!, you'll see the data in the file below.

<%
use CGI;
my $q = new CGI({}); # can't use CGI for input for now
print $q->start_multipart_form();
print $q->filefield('uploaded_file','starting value',40,80);
print $q->submit('Upload File');
print $q->endform();
%>

<% if(my $filehandle = $Request->{Form}{uploaded_file}) { %>
uploaded file handle: <%=$filehandle%>
<pre>
UPLOADED DATA
=============
<% 
	while(<$filehandle>) { 
		print $Server->HTMLEncode($_);	
	}
%>
</pre>
<% } %>

<!--#include file="footer.inc"-->
	 

