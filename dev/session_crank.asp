<%
use Time::HiRes qw(time);
$Session->{1} = 0;
my $num = 2000;
my $i = 0;
my $start = time; 
while(1) {
	last if $i++ >= $num;
	$Session->{1}++;
}
my $time = time() - $start;
%>	
<html>
<body>
total time: <%=$time%> <br>
increments per sec: <%=($num / ($time))%> <br>
incremented to: <%= $Session->{1} %>


