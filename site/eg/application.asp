#!/usr/local/bin/perl5 asp

<% 
	use strict;
	use DemoASP; 
	my $demo = &DemoASP::new($Request);
%>
<html>
<head><title><%=$demo->{title}%></title></head>
<body bgcolor=<%=$demo->{bgcolor}%>>

<% 
	# Locking
	# --------
	# reads and writes to $Application as well as $Session are
	# always locked to ensure concurrency, but if you want to 
	# make sure that you have the only access during
	# some block of commands, then use the Lock() and UnLock()
	# functions

	$Application->Lock();
	$Application->{Count}+=3;
	$Application->UnLock();

%>
We just incremented the $Application->{Count} variable by 3.
Here is the value of the $Application->{Count} variable... <br>
<b><%=$Application->{Count}%></b>
<p>
We reset this value to 20 every Application_OnStart.  Check
out the global.asa!
<p>
<a href="source.asp?file=<%=$Request->ServerVariables("SCRIPT_NAME")%>">
view this file's source
</a>
</body>
</html>
