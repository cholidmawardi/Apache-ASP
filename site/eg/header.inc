<% 
	use DemoASP; 
	$demo = &DemoASP::new;
%>
<html>
<head><title><%=$title || $demo->{title}%></title></head>
<body bgcolor=<%=$_[0] || $demo->{bgcolor}%> alink=#ff5599 vlink=#993399>

<table border=0 cellpadding=3 cellspacing=0 width=100%>
<tr bgcolor=#ff4488>
	<td><img border=0 src=../apache_asp.gif alt="Apache::ASP"></td>
	<td align=right>
		<a href=http://perl.apache.org><img 
			src=../powered_by_modperl.gif border=0
			alt="Powered by ModPerl & Apache"
			></a>
		<a href=http://www.nodeworks.com/asp/><img 
			src=../powered_by_apache_asp.jpg border=0
			alt="Powered by Apache::ASP"
			></a>
	</td>

	</td>
</tr>
<tr bgcolor=gray><td colspan=2>
	<font size=+0 color=white><b><%=$title || $demo->{title}%></b></font>
</td></tr>

<%
# if we are serving from nodeworks.com or chamas.com, then use banner
if($Request->ServerVariables('HTTP_REFERER') =~ /nodeworks\.com|chamas\.com/) {
	my $PageCount = 50 + int rand 25;
	%>
	<tr><td colspan=2>
	<!-- BEGIN LINKEXCHANGE CODE --> 
	<center><iframe src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showiframe?" 
	width=468 height=60 marginwidth=0 marginheight=0 hspace=0 vspace=0 frameborder=0 scrolling=no>
	<a href="http://leader.linkexchange.com/<%=$PageCount%>/X709880/clickle" target="_top"><img width=468 
	height=60 border=0 ismap alt="" 
	src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showle?"></a></iframe>
	<br><a href="http://leader.linkexchange.com/<%=$PageCount%>/X709880/clicklogo" 
	target="_top"><img src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showlogo?" 
	width=468 height=16 border=0 ismap alt=""></a><br></center>
	<!-- END LINKEXCHANGE CODE -->
	</tr></td>
<% 
} 
%>
</table>
<br>


