#!/usr/local/bin/perl5 asp

<!--#include file=header.inc-->

<% 
die;
$Response->{Clean} = 0;
use File::Basename;

my $file = $Request->QueryString('file');
if($file) {
    ## print contents of file here	
    local *FILE;    
    unless(open(FILE, &File::Basename::basename($file))) {
	print "Can't read $file\n";
	$Response->End();
    }
    local $/ = undef;
    my $data = <FILE>;
    close FILE;
    $data =~ s|^\#\!\/[^\n]+\n||sg;
    $data =~ s/^\s+//s;
    $data =~ s/\s+$//s;
    %>

<h3>Source of file <%=$file%>:</h3>
<pre>
<%=$Server->HTMLEncode($data)%>
</pre>	     

    <%	
} else {
    $Response->Write("No file to be displayed");
}
%>

<!--#include file=footer.inc-->


