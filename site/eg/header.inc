<% 
	use vars qw($demo $title);
	use DemoASP; 
	$demo = &DemoASP::new;
	my $gifdir = (-e '../apache_asp.gif') ? '..' : '../..';
%>
<html>
<head><title><%=$title || $demo->{title}%></title></head>
<body bgcolor="<%=$_[0] || $demo->{bgcolor}%>" alink="#ff5599" vlink="#993399">

<table border="0" cellpadding="3" cellspacing="0" width="100%">
<tr bgcolor="#ff4488">
  <td><img border="0" src="<%=$gifdir%>/apache_asp.gif" alt="Apache::ASP" /></td>
  <td align="right" width="300">
    <a href="http://perl.apache.org"><img src="<%=$gifdir%>/powered_by_modperl.gif" border="0" alt="Powered by ModPerl &amp; Apache" /></a> 
    <a href="http://www.nodeworks.com/asp/"><img src="<%=$gifdir%>/powered_by_apache_asp.jpg" border="0" alt="Powered by Apache::ASP" /></a> 
    <a href="http://www.nodeworks.com/partner.htm?partner_id=apacheasp"><img 
      src="<%=$gifdir%>/nodecheck_button.gif" border="0" alt="Links Checked by NodeWorks" /></a>
  </td>
</tr>
<tr bgcolor="gray" width="100%">
  <td><font size="+0" color="white"><b><%=$title || $demo->{title}%></b></font></td>
  <td align="right">
    <% 
       my $date = HTTP::Date::time2iso(); 
       $date =~ s/:\d\d$//;
     %>
    <font color="white" size="-1"><%=$date %> PST</font>
  </td>
</tr>

<%
# if we are serving from nodeworks.com or chamas.com, then use banner
if($Request->ServerVariables('HTTP_REFERER') =~ /nodeworks\.com|chamas\.com/ 
   and $0 !~ /\.xml$/
   ) {
	my $PageCount = 50 + int rand 25;
	%>
	<tr><td colspan="2">

		<!--- Begin HitExchange Code --->
               <CENTER><TABLE BORDER=0 CELLPADDING=0 CELLSPACING=0><TR><TD>
               <TABLE BORDER=0 BGCOLOR="#0000FF" CELLPADDING=1 CELLSPACING=0>
               <TR><TD><A HREF="http://gif.hitexchange.net/HX589936/468x60/<%=$PageCount%>" TARGET="_top">
               <IMG SRC="http://gif.hitexchange.net/HX589936/468x60/<%=$PageCount%>.gif" BORDER=0
                 HSPACE=0 WIDTH=468 HEIGHT=60 ALT="Banner Ad"></A></TD>
               </TR></TABLE></TD></TR><TR><TD ALIGN=CENTER>
               <A HREF="http://gif.hitexchange.net/HX589936/468x15/map" TARGET="_top">
               <IMG SRC="http://gif.hitexchange.net/logo/468x15.gif" BORDER=0 
                 HSPACE=0 ISMAP WIDTH=468 HEIGHT=15 ALT="Click!"></A></TD>
               </TR></TABLE></CENTER>
               <!--- End HitExchange Code --->

=pod

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

=cut

	</tr></td>
<% 
} 
%>
</table>
<br />


