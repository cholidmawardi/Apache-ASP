<% 
	use DemoASP; 
	$demo = &DemoASP::new($Request);
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>


<% $Application->{count}+=3;%>
We just incremented the $Application->{count} variable by 3.
Here is the value of the $Application->{count} variable... 
<%=$Application->{count}%>
<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>
