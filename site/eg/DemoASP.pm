
package DemoASP;
use File::Basename;

sub new {
    my($request) = $main::Request;
    my($env) = $request->ServerVariables();

    my $basename = &File::Basename::basename($0);
    my($title) = "Demo ASP: ". $basename;
    my($self) = bless {
	bgcolor => white,
	env => $env,
	title => $title,
	file => $basename
	};

    $self;
}

1;
