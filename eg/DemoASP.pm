#!perl

package DemoASP;
use File::Basename;

sub new {
    my($request) = @_;
    my($env) = $request->ServerVariables();

    my($title) = "Demo ASP: ".&File::Basename::basename($env->{"SCRIPT_NAME"});
    my($self) = bless {
	bgcolor => white,
	env => $env,
	title => $title
	};

    $self;
}

1;
