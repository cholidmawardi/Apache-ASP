#!/usr/local/bin/perl5 asp

<!--#include file="header.inc"-->

This example shows you how to use Apache::ASP to handle file uploads.
You need to have a recent version CGI.pm to use this facility.
Just click Browse..., select your file, hit 'file upload' and 
voila!, you'll see the data in the file below.
<p>
Note that the current limit set on uploads for this demo is
<tt><%=($CGI::POST_MAX == -1) ? 'NONE' : "$CGI::POST_MAX bytes" %></tt>.

<%
use CGI;
my $q = new CGI; 
print $q->start_multipart_form();
print $q->hidden('file_upload', 'Hidden File Upload Form Text');
print $q->filefield('uploaded_file','starting value',40,80);
print $q->submit('Upload File');
print $q->endform();
my $filehandle;
%>

<% if($filehandle = $Request->{Form}{uploaded_file}) { %>
hidden text: <%=$Request->Form('file_upload') %><br>
uploaded file name: <%=$filehandle%>
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
	 

