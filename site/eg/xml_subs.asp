
<my:include src='header.inc' />

This is a demonstration of the XMLSubsMatch extension which
allows for the developer to construct a set of custom XML style
tags for use in ASP scripts.  These tags could be used 
to render entire XML documents, or even simply give some nice
short cuts for use when site building.
<p>

=pod
  This part just to demo embedding normal ASP constructs
  in the XMLsubs, which was no easy trick to implement!
=cut

Currently, XMLSubsMatch is set to:
<my:ttb> 
  <% $Response->Write('['); %>
  <%=$Server->Config('XMLSubsMatch')%> 
  <% $Response->Write(']'); %>
</my:ttb>
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

Note that XMLSubs tags of the form <my:ttb>foo:bar</my:ttb> will be changed into a
call to <my:ttb>&foo::bar()</my:ttb>, so that the XML concept of tag prefix
namespaces is translated to the concept of perl packages.
<p>

<my:table width=200 title="Title Box" border=3>
  <h3>XML Subs Demo</h3>
=pod
  <my:table>
    Double Table to Show Embedded Tags
  </my:table>
=cut
</my:table>
<p>

<% for("yellow", "red", "blue") { %>
	<my:table bgcolor=$_ width=200 title=ucfirst($_)." Box" border=5>
		Colored Box
	</my:table>
	<p>
<% } %>
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
	     cellpadding => 3,
	     cellspacing => 0,
	     %$args
	    );


	%>
		<table <%=join(' ', 
			       map { "$_=$args{$_}" } keys %args,
			      ) %> 
				>
		<%=($title ? "<tr><td bgcolor=black><font color=white>$title</font></td></tr>" : '') %>
		  <tr><td>
		    <%=$args->{bgcolor} ? ucfirst($args->{bgcolor}) : '' %>
		    <%=$text%>
		  </td></tr>
		</table>
	<%
}
%>
