#!/usr/local/bin/perl5 asp

<!--#include file=header.inc-->

<%
	use File::Basename;
	unless($Session->{staged} > 0) {
		$Session->{staged} = 1;
		# $Response->{Expires} = 3600; # doesn't work to auto redirect browser later
		# with time param, so doesn't think it is redirecting to itself
		$Response->Redirect($Server->URL(basename($0), { params => time() }));
	}

	my $form = $Request->Form();

	# process form here
	if($form->{increment}) {
		$Session->{Count}++;
	} elsif($form->{timeout}) {
		$Session->Timeout(.25);
	} elsif($form->{abandon}) {
		$Session->Abandon();
	}
	
	@rows = (
		 '$Session->{Count}',
		 '$Session->{Timeout}',
		 '$Session->{SessionID}'
		 );
%>

<%= $Server->URL('http://offsite.html') %><br>
<%= $Server->URL('http://onsite.asp') %>

This is a hacked up version of the session.asp <b>$Session</b>
demo that uses a combination of the <b>SessionQueryStringID</b> setting
and <b>$Server->URL()</b> to enable cookieless sessions.  Just turn
off your cookies, and enjoy the cookieless session management.

<center>
<table border=1>
<tr><td colspan=2 align=center><b>Session Object Demonstration</b></td></tr>
<form action=<%=$Server->URL($demo->{file})%> method=POST>
<tr>
	<td colspan=2 align=center>
	<input type=submit name=increment value="Increment Count">
	<input type=submit name=timeout   value="Timeout 15 Seconds">
	<input type=submit name=abandon   value="Abandon">
	<td>
</tr>
</form>
<% for (@rows){ %>
	<tr>
		<td><tt><%=$Server->HTMLEncode($_)%></tt></td>		 
		<td><%=eval($_) || $@%></td>
	</tr>
<% } %>
</table>
</center>
<p>
The value for $Session->{Count} gets reset to 10 on every session start
in the global.asa file.

<!--#include file=footer.inc-->


