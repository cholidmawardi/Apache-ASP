#!perl -w

package T;
use Carp qw(cluck);
no strict 'vars';

sub new {
    my($class, $data, $input) = @_;
    $class ||= 'T';
    bless {
	'data' => $data, 
	'input' => $input
	}, $class;
}    

sub ok {
    $_[0]->{t}++;
    $_[0]->{buffer} .= "ok\n";
}

sub not_ok {
    my($self, $warn) = @_;

    if($warn) {
	cluck $warn;
    }
    
    $self->{t}++;
    $self->{buffer} .= "not ok\n";
}

sub add {
    $_[0]->{buffer} .= "$_[1]\n";
}

sub test {
    my($self) = @_;
    my($k, $v);

    while(($k, $v) = each %{$self->{data}}) {
	$test = "$k=$v";
	if($self->{input} =~ /\[\[$test\]\]/) {
	    $self->ok();
	} else {
	    $self->not_ok();
	    print "$test data not found\n";
	}
    }
}

sub done {
    print "1..$_[0]->{t}\n";
    print $_[0]->{buffer};
}

sub do {
    my($class, $data, $input) = @_;

    my $self = new($class, $data, $input);
    $self->test();
    $self->done();

    1;
}

1;
