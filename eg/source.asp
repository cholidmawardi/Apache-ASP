<% 
	use DemoASP; 
	$demo = &DemoASP::new($Request);
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>

<% 
	use DemoASP;
	use File::Basename;
	use CGI;

	$file = $Request->QueryString('file');
	$cgi = new CGI;
	if($file) {
		## print contents of file here	
		my($fh) = new FileHandle(&File::Basename::basename($file));
		my $data = join("", $fh->getlines());	
		$data = $cgi->escapeHTML($data);
%>

<h3>Source of file <%=$file%>:</h3>
<pre>
<%=$data%>
</pre>	

<%	
	} else {
		$Response->Write("No file to be displayed");
	}
%>

<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>
