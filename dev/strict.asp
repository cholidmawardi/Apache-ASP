<% 
package SomeModule;
sub new { print @_; };
my $x = new SomeModule(-id=>24, -login=>'moo');
%>
