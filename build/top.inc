<%

use File::Basename;
use strict;
use vars qw( 
    $NavColor $LinkColor $NavColSpan $Ads $PageCount $DarkRowColor $VLinkColor 
    $BodyWidth
    );

#$NavColor = '#ffcccc';
#$NavColor = '#ffbbbb';
$NavColor = '#005196';
$LinkColor = '#063678';
$NavColSpan = 2;
$DarkRowColor = $LinkColor;
$VLinkColor = '#993399';
$BodyWidth = '98%';

my $basename = basename($0);
my($baseprefix) = split(/\./, $basename);
my $section = $FILES{$baseprefix} || die("no section for $baseprefix");
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

my $title = "$module :: ".uc(lc $data->{name});
if($basename eq 'index.html') {
	$title .= " [ apache+asp+perl = perl::apache::asp ]";	
}

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
<body bgcolor=black link=<%=$LinkColor%> alink=#ff5599 vlink=<%=$VLinkColor%>
marginheight=0 marginwidth=0 leftMargin=0 topMargin=0>

<% if($Ads) { %>
<center>
<table border=0 cellpadding=3 cellspacing=0 width=100%>
<tr>
<td><!--#include file=ad.inc--></td>
</tr></table>
</center>
<% } %>


<center>
<table border=0 cellpadding=0 width=<%=$BodyWidth%> cellspacing=8>
<tr><td align=center>

<table border=0 cellpadding=3 width=100% cellspacing=0>
<tr bgcolor=<%=$LinkColor%>>
<td>
	<table border=0 cellpadding=1 cellspacing=0 width=100%>
	<tr>
	<td><img border=0 src=asptitlelogo.gif alt="<%=$module%>"></td>	
	<% if($Ads) { %>
		<form action=apps/search/index.asp>
		<td align=right valign=center>
		  <input type=text name=search size=20>
		</td>
		<td align=left valign=center>
  		  <input type=submit value=Search>
		</td>
		</form>		
	<% } else { %>
		<td align=right></td>
	<% } %>
	</tr>
	</table>
</td>
</tr>
<tr>
  <td bgcolor=<%=$NavColor%> align=center>
    <b>
    <font size=-1 face=verdana color=#f0e800>Web applications with Apache + mod_perl</font>  
    </b>
  </td>
</tr>
</table>

<table border=0 cellpadding=10 cellspacing=0 width=100% bgcolor=<%=$NavColor%>>
<tr>
<td valign=top width=120 bgcolor=<%=$NavColor%>>
    
        <table cellpadding=5 cellspacing=0 border=1 bgcolor=white><tr><td>

	<table border=0 cellpadding=0 cellspacing=0 width=105 bgcolor=white>
	
	<% 
	for my $top (@{$ASP->{stack}}, 'hr', { name=> 'EXAMPLES', file => 'eg/index'}) { 
		if($top eq 'hr') {
			%><tr><td colspan=<%=$NavColSpan%>><hr size=1></td></tr><%
			next;
		} elsif(! $top) {
			%><tr><td colspan=<%=$NavColSpan%>>&nbsp;</td></tr><%
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

		my $here = ($basename eq $file) ? 1 : 0;
		my $link;
		if($here) {
			$link = "<font color=$VLinkColor>$top->{name}</font>";
		} else {
			$link = "<a href=$file style=text-decoration:none><font color=$LinkColor>$top->{name}</font></a>";
		} 
		%>
		<tr>

		<td><font size=-2 face="verdana" color=<%=$VLinkColor%>><b><nobr><%= 
				$here ? $Server->HTMLEncode("%") : "&nbsp;"
				%></nobr></b></font></td>

		<td bgcolor=white><font face="verdana,arial" size=-1><b><nobr><%=
			$link
		%></nobr></b></font></td>		

		</tr>
		<%
	}
	%>
	</table>

	</td></tr>
	</table>

		<br>
		<center>
		<a href=http://www.nodeworks.com/asp/><img 
			src=powered_by_apache_asp.jpg border=0
			alt="Powered by Apache::ASP"
			></a>
		<br>
		<a href=http://perl.apache.org><img 
			src=powered_by_modperl.gif border=0
			alt="Powered by ModPerl and Apache"
			></a>
		<br>
		<a href=http://www.nodeworks.com/partner.htm?partner_id=apacheasp><img 
			src=nodecheck_button.gif border=0
			alt="Links Checked by NodeWorks"
			></a>
		</center>


</td>


<% # BODY OF DOC %>
<td valign=top bgcolor=white>
<font size=+0 face=verdana,arial>

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
if(@order > 1) {
	# if any change in levels, then we get some headers going
	my $last_level;
	if(grep($order[$_]->{level} != $order[$_ + 1]->{level}, 0..($#order-1))) {
		$last_level = 100; # really low so first will be a header
	} else {
		$last_level = $order[0]->{level};
	}

	for $data (@order) {
		warn "$last_level, $data->{level} $data->{name}\n";
		if($last_level != $data->{level}) {
			if($last_level > $data->{level}) {
				warn "pushing blank\n";
				push(@links, '');
			}
			$last_level = $data->{level};
		}		
		push(@links, "<a href=#".$Server->URLEncode($data->{name}).">$data->{name}</a>");
	}
	%>

	<hr size=1>
	<table width=100% border=0 cellpadding=1 cellspacing=3>
	<tr>
	<td valign=top><font face="lucida console" size=-1>
	<ul>
	<% 
	my $half = int((@links+1) / 2);
	my $index;	

	my $hilite_first;
	unless($links[0]) {
		$hilite_first = 1;
		shift @links;
	}

	for(my $i=0; $i<$half; $i++) { 
		%>
		<tr>
		<% for $index ($i, $i+$half) { 
			if(! defined $links[$index] && $index != 0) {
				print "<td>&nbsp;</td>";
				next;
			}
			my $bgcolor = '';
			if($index == 0) {
#				unless($links[$index+1]) {
#					$bgcolor = $NavColor;
#				}
				if($hilite_first) {
					$bgcolor = $NavColor;
				}
			} elsif(! $links[$index-1]) {
				$bgcolor = $NavColor;
			}
			%>
			<td valign=top <%= $bgcolor ? "bgcolor=$bgcolor" : '' %>>
			<font face="lucida console" size=-1>
			<% 
			if(($index == 0 and $hilite_first) || ! $links[$index-1]) {
			        $links[$index] =~ s|\>(.*?)\<|><font color=white>$1</font><|i;
				print "<font color=white><b>$links[$index]</b></font>";
			} else {
				print $links[$index];
			}
			%>
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

</font>
</td>
</tr>
<tr bgcolor=<%=$DarkRowColor%>>
	<td colspan=2 align=center width=80%>
	<font face=verdana color=white size=-1>
	Copyright &copy; 1998-2000, Joshua Chamas, 
	<a href=http://www.chamas.com><font color=white>Chamas Enterprises Inc.</font></a>
	</font>
	</td>
</tr>
</table>

</td></tr>
</table>
</center>

</body>
</html>
