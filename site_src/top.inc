<%

use File::Basename;
#$NavColor = '#ffcccc';
$NavColor = '#ffbbbb';

my $basename = basename($0);
($basename) = split(/\./, $basename);
my $section = $FILES{$basename} || die("no section for $basename");
my ($data) = grep($_->{name} eq $section, @{$ASP->{stack}});
my ($copy) = grep($_->{name} eq 'COPYRIGHT', @{$ASP->{stack}});
my ($desc) = grep($_->{name} eq 'INTRO', @{$ASP->{stack}});
my ($keywords) = grep($_->{name} eq 'KEYWORDS', @{$ASP->{stack}});

$desc ={%$desc};
$copy->{body} =~ s/\n\n.*$//sg;
$desc->{body} =~ s/\n\n.*$//sg;

my %meta = (
	'description' => $desc->{body},
	'keywords' => $keywords->{body},
	);

$data || die("can't get data for $section");
my $module = "Apache :: ASP";
my $title = "$module :: ".uc(lc $data->{name})." [ Active Server Pages for Apache with mod_perl ]";

%>

<html>
<head>
<title><%=$title%></title>

<% 
if($0 =~ /index.html$/) {
	for (keys %meta) { 
		%>
		<meta name="<%=$_%>" content="<%=$Server->HTMLEncode($meta{$_})%>">
		<% 
	} 
}
%>

</head>
<body bgcolor=white link=#3355cc alink=#ff5599 vlink=#993399>

<table border=0 cellpadding=5 cellspacing=0 height=95% width=100%>
<tr bgcolor=#ff4488>
<td colspan=2>
	<table border=0 cellpadding=0 cellspacing=0 width=100%>
	<tr>
	<td><img border=0 src=apache_asp.gif alt="<%=$module%>"></td>
	<td align=right>
=pod
		<a href=http://perl.apache.org><img 
			src=powered_by_modperl.gif border=0
			alt="Powered by ModPerl & Apache"
			></a>
		<a href=http://www.nodeworks.com/asp/><img 
			src=powered_by_apache_asp.jpg border=0
			alt="Powered by Apache::ASP"
			></a>
=cut
	</td>
	</tr>
</td>
</tr>
</table>

<tr>

<td valign=top bgcolor=<%=$NavColor%>>
	<table border=0 cellpadding=0 cellspacing=0 width=100>
	<tr><td align=center><hr size=1></td></tr>

	<% 
	my $top;
	for $top (@{$ASP->{stack}}, '', { name=> 'EXAMPLES', file => 'eg/index'}) { 
		unless($top) {
			%><tr><td><hr size=1></td></tr><%
			next;
		}

		my $file;
		if($top->{file}) {	
			$file = $top->{file};
		} else {
			($file) = grep($top->{name} eq $FILES{$_}, keys %FILES); 
		}
		$file = "$file.html";
		next unless (-e $file);

		%>
		<tr>
		<td><a href=<%=$file%>><font face=verdana size=-1 color=#3355cc><%=$top->{name}%></font></a></td>
		</tr>
		<%
	}
	%>
	<tr>
		<td align=center>
		<hr size=1>
		<a href=http://perl.apache.org><img 
			src=powered_by_modperl.gif border=0
			alt="Powered by ModPerl & Apache"
			></a>
		<a href=http://www.nodeworks.com/asp/><img 
			src=powered_by_apache_asp.jpg border=0
			alt="Powered by Apache::ASP"
			></a>
		<hr size=1>
		</td>
	</tr>
	</table>
</td>

<td valign=top>
		</center>
	<% if($Ads) { 
		$PageCount++;
		%>
	<!-- BEGIN LINKEXCHANGE CODE --> 
	<center><iframe src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showiframe?" 
	width=468 height=60 marginwidth=0 marginheight=0 hspace=0 vspace=0 frameborder=0 scrolling=no>
	<a href="http://leader.linkexchange.com/<%=$PageCount%>/X709880/clickle" target="_top"><img width=468 
	height=60 border=0 ismap alt="" 
	src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showle?"></a></iframe>
	<br><a href="http://leader.linkexchange.com/<%=$PageCount%>/X709880/clicklogo" 
	target="_top"><img src="http://leader.linkexchange.com/<%=$PageCount%>/X709880/showlogo?" 
	width=468 height=16 border=0 ismap alt=""></a><br></center>
	<!-- END LINKEXCHANGE CODE -->
	<% } %>
<%
my @stack;
my @order;
push(@stack, $data);
while(@stack) {
	my $data = shift @stack;
	unshift(@stack, @{$data->{stack}});
	push(@order, $data);	
}

print pod2html($data->{body}, $data->{name}, $data->{level});

my @links;
$data = shift @order;
if(@order > 2) {
	my $last_level = $order[0]->{level};
	for $data (@order) {
		if($last_level != $data->{level}) {
			push(@links, '');
			$last_level = $data->{level};
		}		
		push(@links, "<a href=#".$Server->URLEncode($data->{name})."><font color=#3355cc>$data->{name}</font></a>");
	}
	%>

	<hr size=1>
	<table width=100% border=0 cellpadding=2 cellspacing=0>
	<tr>
	<td valign=top><font face="lucida console" size=-1>
	<ul>
	<% 
	my $half = int((@links+1) / 2);
	my $index;
	for(my $i=0; $i<$half; $i++) { 
		%>
		<tr>
		<% for $index ($i, undef, $i+$half) { 
			if(! defined $index) {
				print "<td>&nbsp;</td>";
				next;
			}
			my $bgcolor = '';
			if($index == 0) {
				unless($links[$index+1]) {
					$bgcolor = $NavColor;
				}
			} elsif(! $links[$index+1] && ! $links[$index-1]) {
				$bgcolor = $NavColor;
			}
			%>
			<td valign=top <%= $bgcolor ? "bgcolor=$bgcolor" : '' %>>
			<font face="lucida console" size=-1>
			<%= $links[$index] %>
			</font>
			</td>
		<% } %>					
		</tr>
		<%
	} 
	%>	
	</table>
	<hr size=1>
	<p>
<%
}

for $data (@order) { 
	%>
	<p>
	<a name=<%=$Server->URLEncode($data->{name})%>></a>
	<%=pod2html($data->{body}, $data->{name}, $data->{level})%>
	<%
}
%>

</td>
</tr>
<tr bgcolor=#555555>
	<td colspan=2 align=center width=80%>
	<font face=verdana color=white size=-1><%=$copy->{body}%></font>
	</td>
</tr>
</table>
</body>
</html>
