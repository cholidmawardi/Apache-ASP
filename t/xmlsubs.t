use Apache::ASP;
&Apache::ASP::CGI::do_self(
	Debug => 2,
	XMLSubsMatch => 'my:\w+'
);

__END__

<my:tag>
  <my:deeptag />
  <my:deeptag></my:deeptag>
</my:tag>
<my:returnok
  onearg=1>ok</my:returnok>
<my:args ok=1 />
<my:args 
   ok=1
   error="Multiline Arguments"
 />
<my:deeptag />
<% $t->eok($Deep == 3, "Deep tag to call twice"); %>
<my:args 
   error="Multiline Arguments"
   ok=1
></my:args>
