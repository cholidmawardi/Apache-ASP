<% 
	use strict;
	use DemoASP; 
	my $demo = &DemoASP::new($Request);
	my $form = $Request->Form();

	# process form here
	if($form->{increment}) {
		$Session->{Count}++;
	} elsif($form->{timeout}) {
		$Session->Timeout(.25);
	} elsif($form->{abandon}) {
		$Session->Abandon();
	}
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>

<center>
<table border=1>
<tr><td colspan=2 align=center><b>Session Object Demonstration</b></td></tr>
<form action=<%=$demo->{file}%> method=POST>
<tr>
	<td colspan=2 align=center>
	<input type=submit name=increment value="Increment Count">
	<input type=submit name=timeout   value="Timeout 15 Seconds">
	<input type=submit name=abandon   value="Abandon">
	<td>
</tr>
</form>
<tr>
	<td>Value of $Session->{Count} </td>
	<td><%=$Session->{Count}%> </td>
</tr>
<tr>
	<td>Session Timeout (in minutes) </td>
	<td><%=$Session->Timeout()%> </td>
</tr>
<tr>
	<td>SessionID Value </td>
	<td><%=$Session->SessionID()%> </td>
</tr>
</table>
</center>
<p>
The value for $Session->{Count} gets reset to 10 on every session start
in the global.asa file.
<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>

