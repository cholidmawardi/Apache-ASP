#!/usr/local/bin/perl5 asp

<!--#include file="header.inc"-->

This example shows you how to use Apache::ASP to handle file uploads.
You need to have a recent version CGI.pm to use this facility.
Just click Browse..., select your file, hit 'file upload' and 
voila!, you will see the data in the file below.
<p>
Note that the current limit set on uploads for this demo is
<tt>	
<%
my $limit = Apache->dir_config('FileUploadMax') || $CGI::POST_MAX;
$limit = ($limit eq '-1') ? 'NONE' : $limit;
print "$limit";
%>
</tt>.

<%
use CGI;
my $q = new CGI; 
print $q->start_multipart_form();
print $q->hidden('file_upload', 'Hidden File Upload Form Text');
print $q->filefield('uploaded_file','starting value',40,80);
print $q->submit('Upload File');
print $q->endform();
%>

<% 
my $filehandle;
if($filehandle = $Request->{Form}{uploaded_file}) { 
	print "<table>";
	my @data = (
	  '$Request->{TotalBytes}', $Request->{TotalBytes},
	  'Hidden Text', $Request->Form('file_upload'),
	  'Uploaded File Name', $filehandle,
	  map { ($_, $Request->{FileUpload}{uploaded_file}{$_}) } 
	  sort keys %{$Request->{FileUpload}{uploaded_file}}
	 );
	while(@data) {
		my($key, $value) = (shift @data, shift @data);
		%>
		<tr>
			<td><b><font size=-1><%=$key%></font></b></td>
			<td><font size=-1><%=$value%></font></td>
		</tr>
		<%
	}
	print "</table>";
	%>

	<pre>
UPLOADED DATA
=============
<% 
	my $temp = $Request->{FileUpload}{uploaded_file}{TempFile};
	open(FILE, $temp) || die("can't open $temp: $!");
	while(<FILE>) { 
		print $Server->HTMLEncode($_);	
	}
%>
	</pre>
<% } %>

<!--#include file="footer.inc"-->
