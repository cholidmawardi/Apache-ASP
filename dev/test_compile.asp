
&my_execute("print ('hi')'");

sub my_execute {
    my $asp_script = shift;
    my $ASP = $main::Server->{asp}
    my $perl_script = $ASP->Parse(\$asp_script);
    my $sub = eval "sub { package $ASP->{GlobalASA}{'package'}; $perl_script }"; 
    $@ && die("error compiling sub: $@");
    eval { &$sub };
    $@ && die("error executing sub: $@");
    1;
}
