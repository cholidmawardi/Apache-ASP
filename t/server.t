use Apache::ASP;
&Apache::ASP::CGI::do_self(NoState => 1, Debug => 0);
$SIG{__DIE__} = \&Carp::confess;

__END__

<% use lib '.';	use T;	$t =T->new(); %>

<% 
my $encode = $Server->URLEncode("test data");
if($encode eq 'test%20data') {
	$t->ok();
} else {
	$t->not_ok('URLEncode not working');
}

$Server->Config('Global', '.');
$t->eok(sub { $Server->Config('Global') eq '.' }, 
	'Global must be defined as . for test'
	);
my $config = $Server->Config;
$t->eok($config->{Global} eq '.', 'Full config as hash');
$t->eok($Server->URL('test.asp', { 'test ' => ' value ' } )
	eq 'test.asp?test%20=%20value%20',
	'basic $Server->URL() encoding did not work'
	);
$t->eok($Server->URL('test.asp', { 'test' => ['value', 'value2'] })
	eq 'test.asp?test=value&test=value2',
	'multi params $Server->URL() encoding did not work'
	);

my $html = '&"<>';
my $final = '&amp;&quot;&lt;&gt;';
$t->eok($Server->HTMLEncode('&"<>') eq $final, "\$Server->HTMLEncode('$html')");
$Server->HTMLEncode(\$html);
$t->eok($html eq $final, "\$Server->HTMLEncode(\\\$html)");
$t->eok($Server->MapInclude('server.t') eq './server.t', "Find executing script in Includes path");

#use Benchmark;
#my $htmlbig = '&"<>' x 25000;
#timethis(10, sub { my $copy = $htmlbig; $copy = $Server->HTMLEncode($copy) });
#timethis(10, sub { my $copy = $htmlbig; $Server->HTMLEncode(\$copy) });

%>

<% $t->done; %>
