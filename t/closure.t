use Apache::ASP::CGI;

$^W = 1;
&Apache::ASP::CGI::do_self(UseStrict => 1, NoState => 1, Debug => 0);

__END__
<% 
my $script =<<SCRIPT;
<\%
my \$x=1;
sub closure {
    my \$y = \$x;
    \$y;
}
%\>
SCRIPT
;

eval { $Response->Include(\$script); };
my $error = $@;
$t->eok($error, "include error");
$t->eok($error =~ /not stay shared/is ? 1 : 0, "not stay shared error");
%>	

