<% 
        use DemoASP; 
        $demo = &DemoASP::new();
	$Response->{Buffer} = 0; 
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>
We are creating a perl syntax error... this should demonstrate 
how error handling is done.  Please check the error log file if 
you are interested in the output there.
<p>
You can turn this error messaging off by setting the Debug variable
in the ASP config to 1 or 0.
<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
<% $Object->SyntaxError(); %>
</body>
</html>
