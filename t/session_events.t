#!/usr/local/bin/perl

#use Apache::ASP;

use lib qw(. .. t);
use ASP;
use T;

use strict;
use File::Basename qw(dirname basename);
#$SIG{__DIE__} = \&Carp::confess;
#$SIG{__WARN__} = \&Carp::cluck;
$SIG{__WARN__} = sub { };

$0 =~ /^(.*)$/;
$0 = $1;
chdir(dirname($0));
$0 = basename($0);

my $t = T->new();

my %config = (
	      'NoState' => 0,
	      'SessionTimeout' => 20,
	      'Debug' => 0,
	      'SessionCount' => 1,
	      'Global' => 'session_events',
	      );

my $r = Apache::ASP::CGI::init($0);
map { $r->dir_config($_, $config{$_}) } keys %config;

my $ASP = Apache::ASP->new($r);
$ASP->Session->{MARK} = 1;
#print STDERR "HERE\n";
#sleep 5;
my @sessions = keys %{$ASP->Application};
#&session_count_ok($ASP, scalar(@sessions));

# cleanup old sessions
for my $session_id ( @sessions ) {
    next if ($session_id eq $ASP->Session->SessionID);
    my $Session = $ASP->Application->GetSession($session_id);
    $Session->Abandon;
}
$ASP->{Internal}{CleanupMaster} = undef;
$ASP->CleanupGroups('PURGE');
$ASP->{Internal}{SessionCount}  = 1;

&session_count_ok($ASP, 1);
$ASP->Session->Abandon;
&session_count_ok($ASP, 1);
$ASP->CleanupGroups('PURGE');
&session_count_ok($ASP, 0);
$ASP->DESTROY;

for(1..10) {
    $ASP = Apache::ASP->new($r);
    &session_count_ok($ASP, $_);
    $ASP->DESTROY;
}

$ASP = Apache::ASP->new($r);
&session_count_ok($ASP, 11);
$ASP->Session->Abandon;
$ASP->CleanupGroups('PURGE');
&session_count_ok($ASP, 10);
$ASP->DESTROY;

$t->done;

## helpers

sub session_count_ok {
    my($ASP, $count) = @_;
    $t->eok($ASP->Application->SessionCount == $count, 
	    "$count sessions should have been counted, found ".$ASP->Application->SessionCount);
}