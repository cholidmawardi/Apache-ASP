<% 
	use DemoASP; 
	$demo = &DemoASP::new($Request);
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>

<table>
<form action="<%=$Request->ServerVariables("SCRIPT_NAME")%>" method=POST>
<tr>
	<td>Your Name:</td>
	<td><input name=name type=text size=40 
		value="<%=$Request->Form('name')%>" >
	</td>
	<td><input type=submit value="Submit Name"></td>
</tr>
</table>

<% if($Request->Form('name')) { %>
	Your name is <%=$Request->Form('name')%>
<% } %>

<p>

<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this files source
</a>
</body>
</html>
