use Apache::ASP;
use lib '.'; use lib qw(t); use T; my $t = T->new();

use Carp;
$SIG{__DIE__} = \&Carp::confess;
$main::TestLoad = 0;
Apache::ASP->Loader('t/load.inc', undef, Debug => 1, Execute => 1);

$t->eok($main::TestLoad, "failed to execute load.inc while loading");
$t->done;
