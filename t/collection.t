use Apache::ASP;
&Apache::ASP::CGI::do_self();

__END__

<% 
for('Form', 'QueryString') {
	# basic assignment & lookup
	my $self = $t->eok($Request->$_(), "no collection for $_ found");
	$Request->$_('test', 'value');
	$t->eok($self->{'test'} eq 'value', "count not set value");
	$t->eok($Request->$_('test') eq 'value', "could not fetch value");

	# array assignment & lookup
	$self->{'array'} = [1,0,2];
	my @values = $Request->$_('array');
	$t->eok(@values == 3, 'array block lookup test failed');

	my $value = $Request->$_('array');
	$t->eok($value == 1, 'array single lookup test failed');

	# Item syntax
	$t->eok($Request->$_()->Item('test') eq 'value', '$Collection->Item(key) lookup syntax');
	$Request->$_()->Item('test', 'value2');
	$t->eok($self->{'test'} eq 'value2', '$Collection->Item(key, value) assignment syntax');
}

$Application->{contents} = 1;
$t->eok($Application->Contents('contents'), '$Collection->Contents(key) lookup syntax');
%>

