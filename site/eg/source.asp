#!/usr/local/bin/perl5 asp

<!--#include file=header.inc-->

<% 
  $Response->{Clean} = 0;
	use File::Basename;

	$file = $Request->QueryString('file');
	if($file) {
		## print contents of file here	
		local *FILE;
		open(FILE, &File::Basename::basename($file)) || die("can't read $file");
		local $/ = undef;
		my $data = <FILE>;
		$data = $Server->HTMLEncode($data);
		close FILE;
%>

<h3>Source of file <%=$file%>:</h3>
<pre>
<%=$data%>
</pre>	

<%	
	} else {
		$Response->Write("No file to be displayed");
	}
%>

<!--#include file=footer.inc-->
