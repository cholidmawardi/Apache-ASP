<my:include src='header.inc' />

This is a demonstration of the XMLSubsMatch extension which
allows for the developer to construct a set of custom XML style
tags for use in ASP scripts.  These tags could be used 
to render entire XML documents, or even simply give some nice
short cuts for use when site building.
<p>
Currently, XMLSubsMatch is set to:<my:ttb> <%=$Server->Config('XMLSubsMatch')%> </my:ttb>
<p>
Whatever tags XMLSubsMatch matches of the form
<pre><%=
$Server->HTMLEncode('
 <matchtag param1="value1" param2="value2">
   text
 </matchtag>
  -- or --
 <matchtag param1="value1" param2="value2"/>
')%></pre>

will be parsed into perl subroutines of matchtag name with
arguments and text passed in, so these subs would be called
respectively for the above XMLMatchSubs:

<pre><%=$Server->HTMLEncode('
&matchtag( { param1 => "value1", param2=>"value2" }, \'text\' );
  -- and --
&matchtag( { param1 => "value1", param2=>"value2" }, \'\');
')
%></pre>

Note that XMLSubs tags of the form <my:ttb><my:ttb>foo:bar</my:ttb></my:ttb> will be changed into a
call to <my:ttb>&foo::bar()</my:ttb>, so that the XML concept of tag prefix
namespaces is translated to the concept of perl packages.
<p>

<my:table width=200 title="Title Box" border=3>
XML Subs Demo
</my:table>
<p>

<% 
my $count = 0;
for("yellow", "red", "blue") { 
	%>
	<my:table bgcolor=$_ width=300 title=ucfirst($_)." Box" border=5>
		Colored Box #<%=++$count%>
		<hr size=1>
		<my:multi count=$count>
			<font size=-1><b>Embedded Tags, Wow!</b></font><br>
		</my:multi>
	</my:table>
	<p>
	<% 
} 
%>
<my:include src="footer.inc"/>


<%

## XMLSubs defined here, note these could be defined in global.asa
## as local subs, but these sub were created in the my::* package
## to show how you might decomp your XMLSubs into your own package

sub my::include {
    my($args, $text) = @_;
    $main::Response->Include($args->{src});
}

sub my::ttb {
    my($args, $text) = @_;
    print "<font face=courier size=-1><b>$text</b></font>";
}

sub my::table {
    my($args, $text) = @_;
    my $title = delete $args->{title};

    my %args = (
	     # set defaults, and override with %$args
	     border => 0,
	     bgcolor => 'white',
	     width => '300',
	     cellpadding => 5,
	     cellspacing => 0,
	     %$args
	    );


	%>
		<table <%=join(' ', 
			       map { "$_=$args{$_}" } keys %args,
			      ) %> 
				>
		<%=($title ? "<tr><td bgcolor=black align=center>
			<font color=white>$title</font>
			</td></tr>" : '') %>
		  <tr><td>
		    <nobr>
		    <%=$args->{bgcolor} ? ucfirst($args->{bgcolor}) : '' %>
		    <%=$text%>
		    </nobr>
		  </td></tr>
		</table>
	<%
}

sub my::multi {
	my($args, $text) = @_;
	for(1..($args->{count})) {
		%> <%=$text%> <%
	}
}

%>
