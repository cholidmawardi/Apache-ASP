#!/usr/local/bin/perl5 asp

<%
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
<!--#include file=header.inc-->

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


