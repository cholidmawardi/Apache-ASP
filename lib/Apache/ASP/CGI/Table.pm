
package Apache::ASP::CGI::Table;

=pod

=head1 NAME

  Apache::ASP::CGI::Table

=head1 DESCRIPTION

Layer for compatibility with Apache::Table objects 
while running in CGI or command line / test mode.

=cut

sub new {
    my $class = shift;
    bless {}, $class;
}

sub set { shift()->{shift()} = shift(); }
sub get { shift()->{shift()}; }
sub unset { delete shift()->{shift()} };
sub clear { %{shift()} = (); };
sub add {
    my($self, $name, $value) = @_;

    my $old_value = $self->{$name};
    if(ref $old_value) {
	push(@$old_value, $value);
    } elsif(defined $old_value) {
	$self->{$name} = [$old_value, $value];
    } else {
	$self->{$name} = $value;
    }
}

sub merge { die("merge not implemented"); }

1;
