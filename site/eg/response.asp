#!/usr/local/bin/perl5 asp

<% 
	use DemoASP; 

	$demo = &DemoASP::new();
	$form = $Request->QueryString();

	# Expires
	$form->{expires} ||= 0;
	$Response->{Expires} = $form->{expires};
	$update_time = &HTTP::Date::time2str(time()+$form->{expires});

	# Buffer
	(defined $Session->{buffer}) 
		|| ($Session->{buffer} = $Response->{Buffer});
	if($form->{buffer}) {
		$Session->{buffer} = ! $Session->{buffer};
	}
	$buffer_display = $Session->{buffer} 
		? "Set Buffer Off" : "Set Buffer On";
	$Response->{Buffer} = $Session->{buffer};

	# Cookie
	if($form->{cookie_name}) {
		$Response->{Cookies}{$form->{cookie_name}} = 
			$form->{cookie_value};
	}
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>

<center>
<table border=1 cellpadding=2>
<tr><td colspan=2 align=center><b>Response Object Demonstration</b></td></tr>
<form action=<%=$demo->{file}%> method=GET>
<tr>
	<td colspan=2 align=center>
	<input type=submit name=buffer value="<%=$buffer_display%>">
	<input type=submit name=clear value="Clear Test">
	<input type=submit name=submit value="Submit">
	<td>
</tr>
<tr>
	<td><b>Input Text</b></td>
	<td><input type=text name=text value="<%=$form->{text}%>"></td>
</tr>
<tr>
	<td><b>Expires In (secs)</b></td>
	<td><input type=text name=expires value="<%=$form->{expires}%>"></td>
<% if($update_time) { %>
<tr>
	<td><b>Expires On</b></td>
	<td><%=$update_time%></td>
</tr>
<% } %>
<tr>
	<td><b>Buffering</b></td>
	<td><%=$Response->{Buffer} ? "On" : "Off"%></td>
</tr>
<tr>
	<td><b>Cookie (Name=Value)</b></td>
	<td>
		<input type=text name=cookie_name 
			value="<%=$form->{cookie_name}%>">
		=
		<input type=text name=cookie_value
			value="<%=$form->{cookie_value}%>">
	</td>
</tr>
<tr>
	<td><b>Cookies*</b></td>
	<td>
	<%
	while(($k, $v) = each %{$Request->Cookies()}) {
		if(ref $v) {
			print "$k:<br>\n";
			for(keys %$v) {
				print "- $v->{$_}=$_<br>\n";
			}				
		} else {
			print "$k=$v\n";
		}
		print "<p>\n";
	}
	%>
	</td>
</tr>

<tr>
	<td><b>Clear Demo</b></td>
	<td>
	<% 
	# printing now aliases to $Response->Write()
	print "
		Here's some text that was added to the box... 
		if you pressed clear and buffering is on,
		you will not see it...
		";

	# demo of $Response->Clear();
	$Response->Flush(); 
	%>
	<!-- inserted text -->
	<table border=1><tr><td>Input Text:<%=$form->{text}%></td></tr></table>
	<%
	if($form->{clear}) {
		$Response->Clear();
	}
	%>
	</td>
</tr>
<tr>
	<td><b>print() demo</b></td>
	<td>
	<% print " perl print() now works! <P>\n"; %>		
	</td>
</tr>

</form>
</table>
</center>
<p>
* Please note that the cookie example takes 2 submits to show up
in the table after setting it because the first time, the header
is sent to the browser, and the 2nd, the browser sends it back.

<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>

