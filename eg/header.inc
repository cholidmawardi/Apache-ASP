<% 
	use DemoASP; 
	$demo = &DemoASP::new;
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$_[0] || $demo->{bgcolor}%>>
