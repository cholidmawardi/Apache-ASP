<%
use lib qw(../../eg);
use vars qw(%CONF %SDB $title);
use File::Recurse;
use Fcntl qw(O_RDWR O_CREAT);
use File::stat;
use File::Basename;

# INIT %CONF
for('DB', 'FileRoot', 'SiteRoot', 'RefreshPeriod', 'FileMatch') {
    $CONF{$_} = Apache->dir_config('Search'.$_) || die("no config for $_");
}
$CONF{FileRoot} =~ /\W/ or 
  die("The FileRoot config must have a non word character in it ".
      "that matches \W, like '/', so a local dir may be specified ".
      "with ./");
  
my $input = $Request->{QueryString}{search} || $Request->{Form}{search};
my $copy = $input;
$copy =~ s/(\,\s|[\s\{\}\(\)%:;=\$\"\'\-\/\#]+)/ /sg;
my @words = split(/\s+/, $copy);
my @dropped;
my @final;
my %final;
for(@words) {
	if(length($_) < 3) {
		push(@dropped, $_);
	} else {
	    $_ = lc $_;
	    push(@final, $_);	
	    $final{$_}++;
	}
}

$title = "Site Search";
if(@final) {
    $Session->{search} = $input;
}
$input ||= $Session->{search};

$Response->{Expires} = -300;
%>

<!--#include file=header.inc-->
<center>
<form action=<%=basename($0)%> method=POST>
<input type=text size=30 name=search value="<%=$Server->HTMLEncode($input)%>" maxlength=50>
<input type=submit value=Search>
</form>
</center>

<% 
if(@dropped) { 
	%>
	The following search terms were dropped from your query:
	<tt>
	<%=join(', ', @dropped)%>
	</tt>
	<p>
	<% 
} 
unless(@final) {
    %> No search performed. <%
      $Response->Include('footer.inc');
    $Response->End();
}

# only one person allowed to search at a time, this is
# in case we ever have to update a stale database
$Application->Lock(); 
tie(%SDB, 'SDBM_File', $CONF{DB}, O_RDWR | O_CREAT, 0640)
  || die("can't tie to $CONF{DB}: $!");
$Server->RegisterCleanup(sub { 
			     untie %SDB;
			     $Application->UnLock();
			 });
&refresh_db(\%SDB, \%CONF);

my %files;
my %matches;
my %found;
no strict qw(refs);
for(keys %SDB) {
    next unless /^(..+?)\:(.+)/;
    my $weight = $final{$1} || next;
    $matches{$1}++;
    $files{$2} = sprintf("%06d", $weight + $files{$2});
    push(@{$found{$2}}, $1);
}

my %rank;
map { $rank{$files{$_}.$_} = $_ } keys %files;

if(keys %matches) {
	print "<b>Matches:</b><tt> ";
	print join(", ", map { "$_: $matches{$_}" } keys %matches);
	print "</tt><p>\n";
	
	print "<font size=-1>\n";
	my $count = 0;
	for(reverse sort keys %rank) {
		my $file = $rank{$_};
		my $found = join(', ', sort @{$found{$file}});
		$Response->Debug("listing ranked $file");
		my($mtime,$title,$summary) = split(/\:\:\:/, $SDB{$file} || '', $3);
		unless($mtime) {
		    $Response->Debug("no data for $file");
		    next;
		}
		unless(-e $file) {
		    $Response->Debug("file $file is gone");
		    next;
		}
		
		my $rel_file = $file;
		$rel_file =~ s/^$CONF{FileRoot}\/?//;
		$title ||= $rel_file;
		%>
		<b><%=++$count%>.</b> <a href="<%= $CONF{SiteRoot}.'/'.$rel_file %>"><%=$title%></a><br>
		<%=$summary%> ...<br>
		<% if($found) { %>
		    <i>Found: <%=$found%></i>
		<% } %>
		<p>
		<%    
	}
} else {
	print "No matches found for your search.";
}
%>
</font>
<!--#include file=footer.inc-->
