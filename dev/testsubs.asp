

<pre>
<Apps:header type="header" title="Moo" foo="moo" />
<Apps:header type=300 />
Hello
message is <msg>aaa</msg>
<Apps:footer/>
</pre>

<% 

sub print_args {
	print "<br>";
	print Data::Dumper->Dump([@_]);
}

sub Apps::header {
	&print_args('header', @_);
}

sub Apps::footer {
	&print_args('footer', @_);
}

sub msg { 
	print "message -- $_[1]";
}

%>
