#!perl -w

=head1 COPYRIGHT

Copyright (c) 1998 Chamas Enterprises Inc. 
All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=head1 NAME

Apache::ASP - Active Server Pages for Apache (all platforms)

=cut Documentation continues at the end of the module.

package Apache::ASP;

sub VERSION { .01; }

use Apache();
use Apache::Constants qw(:common);
use MLDBM;
use SDBM_File;
use Data::Dumper;
use File::stat;
use File::Basename;
use FileHandle;
use Fcntl qw( O_RDWR O_CREAT );
use MD5;

## use Storable;
## problem with Storable with MLDBM, when referencing empty undefined
## value, hangs, and module reloads.
## $MLDBM::Serializer = "Storable"; ## faster than using Data::Dumper
##
$MLDBM::Serializer = "Data::Dumper";

%Apache::ASP::Compiled     = ();
$Apache::ASP::CreateServer = 0;
$Apache::ASP::GlobalASA    = 0;
$Apache::ASP::Md5          = new MD5();

## these define the default routines that get parsed out of the 
## GLOBAL.ASA file
@Apache::ASP::GlobalASARoutines = 
    (
     "Application_OnStart", "Application_OnEnd", 
     "Session_OnStart", "Session_OnEnd"
     );

## only if we support active objects on Win32 do we create
## the server object, which is in charge of object creation
eval { require("Win32/OLE.pm"); };
unless($@) {
    $Apache::ASP::CreateServer = 1;
    use Win32::OLE;
}

sub handler {
    my($r) = @_;

    ##X: fix the error checking please
    return(FORBIDDEN) unless (-e $r->filename());
    # $self->$IsAsp() || return(FORBIDDEN);

    ## ASP object creation, a lot goes on in there!
    my($self) = new($r);

    $self->Debug("debug level: $self->{debug}; r: $r") if $self->{debug};

    ##X: GLOBAL.ASA not supported yet, its lame
    # $self->ProcessGlobalASA(); 

    if($self->IsChanged()) {
	my($script) = $self->Parse();
	$self->Compile($script);
    }
    
    unless($self->{errors}) {
	$r->content_type("text/html");
	$self->Execute();
	$status = DONE;
    }
    
    ## error processing
    if($self->{errors} && ($self->{debug} >= 2)) {
	$r->content_type("text/html");
	$r->print("\n\n");
	$r->print("<pre>");
	$r->print(join("\n---\n", @{$self->{errors_output}}, ""));
	$r->print($self->Escape($self->{compile_error}));
	my($lineno) = 1;
	for(split(/\n/, $self->{compile_output})) {
	    $_ = $self->Escape($_);
	    $r->print($lineno++ . ": $_\n");
	}
	$r->print("\n\n");
	$r->print("</pre>");
	$status = DONE;
    } elsif($self->{errors}) {
	$status = SERVER_ERROR;
    }

    $self->Debug("num errors: $self->{errors}") if $self->{debug};
    $self->DESTROY();
    undef $self; ## make sure we free up all of self now    

    $status;
}

sub new {
    my($r) = @_;

    chdir(File::Basename::dirname($r->filename()));

    ## asp object is handy for passing state around
    my $self = bless { 
	app_start      => 0,  ## set this if the application is starting
	app_state      => '', ## file to tie for app state

	## this is the server path that the client responds to 
	cookie_path    => $r->dir_config(CookiePath),

	## these are set by the Compile routine
	compile_error  => '', 
	compile_output => '', 

	debug          => $r->dir_config(Debug),  ## debug level
	errors         => 0,
	errors_output  => [],
	filename       => $r->filename(),
	id             => '', ## parsed version of filename
	
        ## state file used to internal session timeouts, security etc.
	internal_state  => 0,  
	
	## where all the state and config files lie
	global         => $r->dir_config(Global) || $r->location(),

	mtime          => stat($r->filename())->mtime,  ## better than -M

	## set this if you don't want an Application or Session object
	## available to your scripts
	no_session     => $r->dir_config(NoSession),

	r              => $r, ## apache request object 
	remote_ip      => $r->connection()->remote_ip(),
	security_state => 0,   
	session_start  => 0,  ## set this if we have a new session beginning
	session_state  => 0,  
	session_timeout => ($r->dir_config(SessionTimeout) * 60) || 1200,

	## special objects for ASP app
	Application    => '',
	Internal       => '',
	Request        => '',
	Response       => '',
	Session        => '',
	Server         => ''
	};
    
    $self->{id} = $self->{filename};
    $self->{id} =~ s/\W/_/gs;

    ## make sure we have a cookie path config'd if we need one for state
    if(! $self->{no_session} && ! $self->{cookie_path}) {
	$self->Error("CookiePath variable not set in config file");
	$self->{cookie_path} = '/'; ## safe default, apps still work
    }

    ## X: do other friendly checks for proper config info here.

    ## initialize the big ASP objects now
    $self->InitObjects();

    $self;
}

sub DESTROY {
    my($self) = @_;
    my($k, $v);

    $self->Debug("destroying asp $self");

    ## free file handles here.  mod_perl tends to be pretty clingy
    ## to memory
    untie %{$self->{Application}};
    untie %{$self->{Internal}};
    untie %{$self->{Session}};

    while(($k, $v) = each %{$self}) {
	undef $self->{$k};
    }
    
}

sub InitObjects {
    my($self) = @_;

    $self->{application_state} = "$self->{global}/.application_state";
    ($self->{Application} = &Apache::ASP::Application::new($self)) 
	|| $self->Error("can't get application state");
    
    ## if we are tracking state, set up the appropriate objects
    if(! $self->{no_session}) {
	if($self->{global}) {	
	    $self->{session_state} = "$self->{global}/.session_state";
	    $self->{security_state} = "$self->{global}/.security_state";
	    $self->{internal_state} = "$self->{global}/.internal_state";
	    
	    ## tie to the application internal info
	    tie(%{$self->{Internal}}, 'Apache::ASP::State', 
		$self->{internal_state}, O_RDWR|O_CREAT)
		|| $self->Error("can't tie to internal state");

	    ## Session state is dependent on Application State begin set first
	    $self->{Session} = &Apache::ASP::Session::new($self);    

	} else {
	    $self->Error("global [$self->{global}] for asp is not a directory");
	}
    } else {
	$self->Debug("no state requested");
    }
    
    if($Apache::ASP::CreateServer) {
	$self->{Server} = &Apache::ASP::Server::new($self);
	$self->Debug("created server object: $self->{Server}");
    }
    
    ## always create these
    $self->{Request}  = &Apache::ASP::Request::new($self);
    $self->{Response} = &Apache::ASP::Response::new($self);

    $self;
}

## global.asa processes, whether or not there is a global.asa file.
## if there is not one, the code is left blank, and empty routines
## are filled in
##
sub ProcessGlobalASA {
    return if ($Apache::ASP::GlobalASA);
    my($self) = @_;

    $self->Debug("processing GlobalASA for $$") if $self->{debug};
    $Apache::ASP::GlobalASA = 1;

    my($filename) = "$self->{global}/GLOBAL.ASA";
    my($code) = $self->ReadFile($filename);
    $code =~ s/\<\/?script?.*?\>/\#script tag removed here/igs;
    
    ## fill in code for undefined events
    for(@Apache::ASP::GlobalASARoutines) {
	next if($code =~ /sub $_/s);	   
	$code .= "\nsub $_ { }\n";
    }
    $self->Compile($code, 'GlobalASA'); 

    $self;
}

sub IsChanged {
    my($self) = @_;
    ($self->{mtime} > $Apache::ASP::Compiled{$self->{id}}) ? 1 : 0;
}        

sub Parse {
    my($self) = @_;
    my($script, $text, $perl);

    my($data) = $self->ReadFile($self->{filename});
    $data =~ s/\<\%\@(.*?)\%\>//s; ## there should only be one of these
    while($data =~ s/^(.*?)\<\%\s*(.*?)\%\>//s) {
	($text, $perl) = ($1,$2);
	$text =~ s/^\s+$//gs;
	$perl =~ s/^\s+$//gs;

	if($text) {
	    $text =~ s/\\/\\\\/gs;
	    $text =~ s/\'/\\\'/gs;
#	    $text =~ s/\"/\\\"/gs;
	    $script .= '$Response->Write(\''.$text.'\');' . "\n";
	}

	if($perl) {
	    if($perl =~ /^\=(.*)/) {
		$perl = '$Response->Write('.$1.');';
	    } 
	    ## PerlScript compatibility
	    $perl =~ s/(\$.*?\(.*?\))\-\>item/$1/sg; 

	    $script .= $perl . "\n";
	}
    }
    
    $text = $data;
    $text =~ s/\\/\\\\/gs;
    $text =~ s/\'/\\\'/gs;
#    $text =~ s/\"/\\\"/gs;
    $script .= '$Response->Write(\''.$text.'\');' . "\n";

    $script;
}

sub ReadFile {
    my($self, $file) = @_;

    my($fh) = new FileHandle($file);
    my $data = join("", $fh->getlines());
    undef $fh;
        
    $data;
}
    
sub Compile {
    local($self, $script, $id, $no_cache) = @_;
    local($package);

    ## if we don't cache the script, it will only be stored as temp,
    ## and will be rewritten next no_cache script is compiled
    if($no_cache) {
	$package = "_NO_CACHE";
    } elsif($id) {
	$package = $id;
    } else {
	$package = $self->{id};
    }
    
    $self->Debug("compiling package: $package; id: $id; no_cache: $no_cache");
    undef &{"Apache::ASP::Compiles::" . $package . "::handler"};
    my($eval) = 
	join("\n", 
	     "package Apache::ASP::Compiles::" . $package . ";" ,
	     '',
	     "use lib qw($self->{global});",
	     '',
	     'sub handler { ',
	     '  my($self, $routine) = @_; ',
	     '  $Application = $self->{Application}; ',
	     '  $Session     = $self->{Session}; ',
	     '  $Response    = $self->{Response}; ',
	     '  $Server      = $self->{Server}; ',
	     '  $Request     = $self->{Request}; ',
	     '  $Response    = $self->{Response}; ',
	     '  $Internal    = $self->{Internal}; ',
	     '  $self = $script = $no_cache = $package = ""; ',
	     '',
	     '  if($routine) { ',
	     '    &$routine; ',
	     '    exit;      ',
	     '  } ',
	     '',
	     $script,
	     '  $Application = $Session = $Response = $Server = ""; ',
	     '  $Request = $Response = ""; ',
	     '  $Internal = ""; ',
	     '}',
	     '1;',
	     );

    Apache->untaint($eval);
    $self->{compile_output} .= $eval . "\n\n";
    
    eval $eval;
    my($rv) = (! $@);
    if($@) {
	$self->Error($@);
	$self->{compile_error} .= "\n$@\n";
    } else {
	$Apache::ASP::Compiled{$package} = $self->{mtime};
    }
    
    $rv;
}

sub Execute {
    my($self, $id, $routine) = @_;

    return if $self->{errors};
    $id = $id ? $id :$self->{id};
    $routine = $routine ? $routine : '';

    $self->{debug} && 
	$self->Debug("execute handler: $handler; id: $id; sub: $routine");
    my $handler  = \&{"Apache::ASP::Compiles::".$id."::handler"};
    eval { &{$handler}($self, $routine) };  
    $@ && $self->Error($@);
    
    my($rv) = (! $@);
    $rv;
}

sub Log {
    my($self, $msg) = @_;

    $msg =~ s/[\r\n]+/ \\\\ /sg;
    $self->{r}->log_error("[asp log] $msg");

    1;
}    

sub Error {
    my($self, $msg) = @_;

    if($msg) {
	$msg =~ s/[\r\n]+/ \\\\ /sg;
	$self->{errors}++;
	push(@{$self->{errors_output}}, $msg);
	## send errors to log, assume running as production server
	$self->{r}->log_error("[asp error] $msg");
    }

    1;
}   

sub Debug {
    return unless $_[0]->{debug};
    
    my($self, $msg) = @_;
    if($msg) {
	$msg =~ s/[\r\n]+/ \\\\ /sg;
	$self->{r}->log_error("[asp debug] $msg");
    }
    
    1;
}

sub Print {
    my($self, $msg) = @_;
    $self->{r}->print($msg);
}

## combo get / set
sub SessionId {
    my($self, $id) = @_;

    ##X: should we set the secure variable here? 
    if($id) {
	$self->{r}->header_out("Set-Cookie", "id=$id; path=$self->{cookie_path}");
    } else {
	my($cookie) = $self->{r}->header_in("Cookie");
	my(@parts) = split(/\;/, $cookie);
	my(%cookie) = map { split(/\=/, $_)} @parts;
	
	$id = $cookie{'id'};
    }

    $id;
}

sub Secret {
    my($self) = @_;

    $md5 = $Apache::ASP::Md5;
    $md5->reset;
    $md5->add($self . $self->{remote_ip} . rand() . time());
    
    $md5->hexdigest();
}
    
sub Escape {
    my($self, $html) = @_;

    $html =~s/&/&amp;/g;
    $html =~s/\"/&quot;/g;
    $html =~s/>/&gt;/g;
    $html =~s/</&lt;/g;

    $html;
}

1;

## Request Object
package Apache::ASP::Request;

sub new {
    my($r) = $_[0]->{r};
    my($self) = bless {};
    my(%query, %form, %env);
    
    %query = $r->args();
    $self->{'QueryString'} = \%query;

    %env = $r->cgi_env();
    $self->{'ServerVariables'} = \%env;

    ## assign no matter what so Form is always defined
    if($r->method eq "POST") {
	%form = $r->content();
    }
    $self->{'Form'} = \%form;

    $self;
}

sub AUTOLOAD {
    return if ($AUTOLOAD =~ /DESTROY/);
    my($self, $index) = @_;

    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/i;
    if(defined($index)) {
	$self->{$AUTOLOAD}{$index};
    } else {
	$self->{$AUTOLOAD};
    }
}

1;

## Response Object
package Apache::ASP::Response;

sub new {
    return bless {r => $_[0]->{r}, first => 0};
}
    
sub Write {
    my($self, $send) = @_;

    ## if this is the first writing from the page, flush a newline, to 
    ## get the headers out properly
    unless($self->{first}) {
	$self->{r}->print("\n");
	$self->{first}++;
    }

    $self->{r}->print($send);
}

sub Expires {
    my($self, $ttl) = @_;
    ##X: how do we handle non 0 ttl's?
    $self->{r}->no_cache() if ($ttl == 0);
}

1;

## Server Object
package Apache::ASP::Server;

sub new {
    bless {asp => $_[0]};
}

sub DESTROY {
    my($self) = @_;
    my($k, $v);

    my(%oles) = %{$self->{oles}};
    while(($k, $v) = each %oles) {
	undef $v;
    }

    undef $self->{oles};
}

sub CreateObject {
    my($self, $name) = @_;
    my($asp) = $self->{asp};

    unless($name) {
	$asp->Debug("no object to create");
	return;
    }

    my($ole) = Win32::OLE->GetActiveObject($name);
    unless($ole) {
	$ole = Win32::OLE->new($name);
    }
    
    if($ole) {
	$self->{oles}{$name} = $ole;
    } else {
	$asp->Error("can't create OLE $name");
    }

    $ole;
}

1;

## Application Object
package Apache::ASP::Application;
use Fcntl qw( O_RDWR O_CREAT );

sub new {
    my($asp) = @_;
    my(%self);

    tie(%self, 'Apache::ASP::State', 
	$asp->{application_state}, O_RDWR|O_CREAT)
	|| $asp->Error("can't tie to application state");
    
    bless \%self;
}

sub DESTROY { 
    my($self) = @_;   
    untie $self;
}

1;

## Session Object
package Apache::ASP::Session;
use Apache;

sub new {
    my($asp) = @_;
    my($id, $state);
    
    ## make sure we have a sessions state directory
    unless(-d $asp->{session_state}) {
	unless(mkdir($asp->{session_state}, 000)) {
	    $asp->Error("failed to create sessions dir");
	    return;
	}
    }
    
    if($id = $asp->SessionId()) {
	$state = Apache::ASP::State::new("$asp->{session_state}/$id");
	$asp->Debug("incoming id: $id; state: $state");
	if($internal = $asp->{Internal}{$id}) {
	    ## user is authentic, since the id is in our internal hash
	    if($internal->{timeout} > time()) {
		## session not expired
		$asp->Debug("session not expired");
		$state->Get();
	    } else {
		## expired, get & reset
		$asp->Debug("resetting state for id $id");
		$state->Init();
	    }
	} else {
	    ## never seen before, someone's hacking

	    ## X: make sure to clean up Internal when garbage
	    ## collecting the session states

	    ## slow them down so provable security
	    ## if we had wire speed authentication, we'd
	    ## have a real security issue, otherwise, the md5
	    ## hash session key is 2^128 in size, so would 
	    ## take arguably too long for someone to try all the 
	    ## sessions before they get garbage collected
	    sleep(1); 
	    $state->Init();

	    ## wish we could do more than just log the error
	    ## but proxying + nat prevents up from securing via ip address
	    $asp->Log("[security] session id $id asked for ".
		      "by ip $asp->{remote_ip}"
		      );
	}
    } else {
	## give user new session id
	my($trys);
	for(1..10) {
	    $trys++;
	    $id = $asp->Secret();

	    if($asp->{Internal}{$id}) {
		$id = '';
	    } else {
		last;
	    }
	}

	$asp->Log("[security] secret algorithm is no good with $trys trys")
	    if ($trys > 3);

	$asp->Error("no unique secret generated")
	    unless $id;

	$asp->Debug("new id $id");
	
	$asp->{session_start}++;
	$asp->SessionId($id);
	$state = &Apache::ASP::State::new("$asp->{session_state}/$id");
	$state->Set();
    }

    if($state) {
	$internal = $asp->{Internal}{$id};
	$internal->{timeout} = time() + $asp->{session_timeout};
	$asp->{Internal}{$id} = $internal;
    } else {
	$asp->Error("can't get state for id $id");
    }

    my(%self); 
    tie %self, 'Apache::ASP::Session', {state=>$state, asp=>$asp, id=>$id};

    \%self;
}	

sub TIEHASH { 
    my($package, $self) = @_;
    bless $self;
}       

sub AUTOLOAD {
    return if ($AUTOLOAD =~ /DESTROY/);
    my($self) = shift;

    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/i;
    $self->{state}->$AUTOLOAD(@_);
}

sub Timeout {
    my($self, $minutes) = @_;

    my($internal_session) = $self->{asp}{Internal}{$self->{id}};
    $internal_session->{timeout} = time() + $minutes * 60;
    $self->{asp}{Internal}{$self->{id}} = $internal_session;

    1;
}    

sub Abandon {
    my($self) = @_;
    $self->Timeout('-1');
}

1;

package Apache::ASP::State;
use Fcntl qw( O_RDWR O_CREAT );

sub new {
    my($file, $permissions) = @_;

    my $self = bless {file => $file};
    if($permissions) {
	$self->Do($permissions);
    }

    $self;
}

sub Get {
    $_[0]->Do(O_RDWR);
}

sub Set {
    $_[0]->Do(O_RDWR|O_CREAT);
}

sub Init {
    my($self) = @_;

    $self->Set();
    $self->{dbm}->CLEAR();

    $self;
}

sub Do {
    my($self, $permissions) = @_;
    return unless ($self->{file} && (defined $permissions));
    
    $self->{dbm} = &MLDBM::TIEHASH('MLDBM', $self->{file}, $permissions, 0666);
}

sub TIEHASH {
    my($type) = shift;
    bless &new(@_), $type;
}

sub AUTOLOAD {
    return if ($AUTOLOAD =~ /DESTROY/);
    my($self) = shift;

    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/i;
    $self->{dbm}->$AUTOLOAD(@_);
}

1;

__END__

=head1 DESCRIPTION

This module provides a Active Server Pages port to Apache.  
Active Server Pages is a web application platform that originated
with Microsoft's IIS server.  Under Apache for both Win32 and Unix,
it allows a developer to create web applications with session
management and perl embedded in static html files.

This is a portable solution, similar to ActiveWare's PerlScript
and MKS's PScript implementation of perl for IIS ASP.  Theoretically,
one should be able to take a solution that runs under Apache::ASP
and run it without change under PerlScript or PScript for IIS.

=head1 INSTALLATION

Apache::ASP installs easily using the make or nmake commands as
shown below.  Otherwise, just copy ASP.pm to $PERLLIB/site/Apache

=begin text

	> perl Makefile.PL
	> make 
	> make install

	* use nmake for win32

=end text

=head1 CONFIG

Use with Apache.  Copy the /eg directory from the ASP installation 
to your Apache document tree and try it out!  You have to put

AllowOverride All

in your <Directory> config section to let the .htaccess file in the 
/eg installation directory do its work.

Here is a sample config in a *.conf Apache configuration file that works,
if you want to skip the /eg installation:

=begin text 

<Location /asp/>    
    ## mandatory
    SetHandler perl-script
    PerlHandler Apache::ASP
    PerlSendHeader On
    Options ExecCGI 

    ## optional flags
    PerlSetVar Debug 0
    PerlSetVar Global c:/tmp
    PerlSetVar CookiePath /
    PerlSetVar NoSession 0
    PerlSetVar SessionTimeout 20
</Location>

=end text

You can use the same config in .htaccess files without the 
Location tag.  I use the <Files ~ (\.asp)> tag in the .htaccess
file of the directory that I want to run my asp application.
This allows me to mix other file types in my application,
static or otherwise.

=head1 ASP Syntax

ASP embedding syntax allows one to embed code in html in 2 simple ways.
The first is the <% xxx %> tag in which xxx is any valid perl code.
The second is <%= xxx %> where xxx is some scalar value that will
be inserted into the html directly.  An easy print.

A simple asp page would look like:

=begin text 

	<!-- sample here -->
	<html>
	<body>
	For loop incrementing font size: <p>
	<% for(1..5) { %>
		<!-- iterated html text -->
		<font size="<%=$_%>" > Size = <%=$_%> </font> <br>
	<% } %>
	</body>
	</html>
	<!-- end sample here -->

=end text

Notice that your perl code blocks can span any html.  The for loop
above iterates over the html without any special syntax.

=head1 The Object Model

The beauty of the ASP Object Model is that it takes the
brunt of the burden of CGI and Session Management off the 
developer, and puts them in objects accessible from any
ASP page.  For the perl programmer, treat these objects
as globals accesible from anywhere in your ASP application.

Currently the Apache::ASP object model supports the following objects:

=begin text

	Object		--	Function
	------			--------
	$Response	--	output
	$Request	--	input
	$Application	--	application state
	$Session	--	session state

=end text

These objects, and their methods are further defined in the 
following sections.

=head1 MORE

I'll put more info on objects here soon.

=head1 QUESTIONS

Please send any questions or comments to Joshua Chamas
at chamas@alumni.stanford.org

=cut








