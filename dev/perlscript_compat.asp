<% @Language=PerlScript %>
<html><body>
<%
#        use strict;
#        use vars qw/$Response/;

	# works
        $Response->{Buffer} = 1;
        $Response->Write('Testing Write: 1,2,3<p>');

	# works
        $Application->Contents->SetProperty('Item', 'XYZ', "Fred");
        my $appvar = $Application->Contents('XYZ');
        print "XYZ = <$appvar>", $Application->Contents('XYZ') , "<br>";

	# what is 'UserId' supposed to be, $Session->SessionID ?
        my $currUserId = $Request->Cookies('UserId')->{Item};
        print $currUserId;

	# works
        $Response->SetProperty('Cookies', 'Testing', 'Extra');
        $Response->SetProperty('Cookies', 'Testing', {'Path' => '/'});
	print "Cookie Testing Value: " . $Request->Cookies(Testing) . "<br>\n";

	# only RFC dates work, no VBScript date compatibility :(
        $Response->Cookies->SetProperty('Item', 'name', 'Cookie');
        $Response->Cookies('name')->{Expires} = "8 Mar 2000 20:40:00";
#        $Response->Cookies('name')->{Expires} = "March 8, 2000 20:40:00";

	# works
        $Response->Cookies('MyCookie')->SetProperty('Item', 'Type1', 'Sugar');
        $Response->Cookies('MyCookie')->SetProperty('Item', 'Type2', 'GingerSnap');
        $Response->Cookies('MyCookie')->{Path} = '/';
	my $dict = $Request->Cookies('MyCookie');
	for(keys %{$dict}) {
		print "Cookie MyCookie key: $_ value: $dict->{$_}<br>\n";
	}
	
	# works
        $Session->Contents->SetProperty('Item', 'Matt', 'Contents');
        print '$Session->Contents(Matt): ' . $Session->Contents('Matt') . "<br>\n";

	# works
        $Session->Abandon;

	# works
        print 'QueryString->{message}: ', $Request->QueryString->Item('message'), "<br>\n\n";

	## what is NumUsers supposed to be?  
        print "\n\n<p>NumUsers: ", $Application->Contents('NumUsers');

%>
<p>
</body></html>	 

