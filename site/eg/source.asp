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


