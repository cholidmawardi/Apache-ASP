<!--#include file="header.inc"-->
The following table lists the sessions that have been
recorded in the global.asa file into $Application.  When
a session ends, its time lived is recorded and displayed
below.  Active sessions are also listed.  
<p>
<%
my $count;
for(keys %{$Application}) {
	next unless ($_ =~ /^Session/);
	$count++;
}
%>
<center>
<%=$count%> Sessions Recorded <br>

<!-- 
	Please read the README or the perldoc Apache::ASP before using
	the following routine in your code, as it is non-portable.
-->
<%=$Application->SessionCount()%> Active Sessions
<p>
<table border=0 width=90%>
	<tr><td colspan=2><hr size=1></td></tr>
<%
for(keys %{$Application}) {
	next unless ($_ =~ /^Session/);

	my $session_id = $_;
	$session_id =~ s/^Session//io;

	my $session_time = ($Application->{$_} eq '?') ?
		"in session" : "$Application->{$_} seconds";

	%>
	<tr bgcolor="#c0c0c0">
		<td><%=$session_id%></td>
		<td><%=$session_time%></td>
	</tr>	
	<tr><td colspan=2><hr size=1></td></tr>
	<%
	$Response->Flush();
}
%>
</table>
</center>
<p>
To see multiple sessions listed you may  
create a 2nd session by closing and then reopening
the browser you are using to view this file, or 
you may also open a 2nd kind of browser to create this 2nd
session.  There is only one session-id generated
per browser session for an asp application.
<p>
This example serves as how one may use the global.asa 
file Session_OnStart and Session_OnEnd commands to
keep track of sessions in $Application.

<p>
<!--#include file="footer.inc"-->
