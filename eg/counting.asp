<% 
	use DemoASP; 
	$demo = &DemoASP::new($Request);
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>
        For loop incrementing font size: <p>
        <% for(1..5) { %>
                <!-- iterated html text -->
                <font size="<%=$_%>" > Size = <%=$_%> </font> <br>
        <% } %>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>
<!-- end sample here -->

