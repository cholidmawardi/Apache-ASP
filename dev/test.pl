
use Benchmark;
use strict;
use Apache::ASP;

my @test_files = glob('test/*.t');
for my $test_file (sort @test_files) {
    open(FILE, $test_file) || die("can't open $test_file for reading: $!");
    my $data = join('', <FILE>);
    close FILE;
    local *0 = $test_file;

    my $t = timeit(1, sub { eval $data });
    my($ok, $not_ok);
    if ($@) {
	line_out($t, $test_file, "failed: $@");
	next;
    }

    line_out($t, $test_file, 'success');
}

sub line_out {
    my($time, $test_file, $message) = @_;
    printf "...%-25s --- %-20s %8.6f seconds\n", $test_file, $message, $time->[1];
}
