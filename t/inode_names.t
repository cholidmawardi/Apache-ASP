use Apache::ASP::CGI;
&Apache::ASP::CGI::do_self(NoState => 1, InodeNames => 0, UseStrict => 1);

__END__
<% 
use File::Basename qw(basename);
use strict;

my $ASP = $Server->{asp};
$ASP->{r}->dir_config('InodeNames', 0);
my $file_id1 = $ASP->FileId(basename($Server->File));
$t->eok(sub { $file_id1 =~ /^__ASP_inode_names_tx.{32}$/ }, "basename FileId()");

my $file_id2 = $ASP->FileId('abc'x200);
$t->eok(sub { $file_id2 =~ /abcx/ and length($file_id1) < 120 }, "long name FileId()");

my $file_id3 = '';
if(my $stat = (stat('.'))[1]) {
    $ASP->{r}->dir_config('InodeNames', 1);
    $file_id3 = $ASP->FileId(basename($Server->File));
    $t->eok(sub { $file_id3 =~ /DEV.+_INODE.+/ }, "InodeNames FileId()");
}

my $file_id4 = $ASP->{id};
$t->eok(sub { $file_id4 =~ /^__ASP_t_inode_names_tx/ }, "Script FileId()");
$t->eok(length($ASP->{compile_checksum}) == 32, "Compile Checksum");

%>	

