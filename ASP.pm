#!perl -w

=head1 NAME

 Apache::ASP - Active Server Pages for Apache (all platforms)

=head1 SYNOPSIS

 SetHandler perl-script
 PerlHandler Apache::ASP
 PerlSetVar Global /tmp # must be some writeable directory

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

=cut Documentation continues at the end of the module.

package Apache::ASP;

sub VERSION { .04; }

#use strict;
use Apache();
use MLDBM;
use SDBM_File;
use Data::Dumper;
use File::stat;
use File::Basename;
use FileHandle;
use Fcntl qw( O_RDWR O_CREAT );
use MD5;
use HTTP::Date;

# use Storable;
# problem with Storable with MLDBM, when referencing empty undefined
# value, hangs, and module reloads.
# $MLDBM::Serializer = "Storable"; # faster than using Data::Dumper
#
$MLDBM::Serializer = "Data::Dumper";


# these define the default routines that get parsed out of the 
# GLOBAL.ASA file
@Apache::ASP::GlobalASARoutines = 
    (
     "Application_OnStart", "Application_OnEnd", 
     "Session_OnStart", "Session_OnEnd"
     );

@Apache::ASP::Contacts    = ('modperl@apache.org', 'chamas@alumni.stanford.org');
%Apache::ASP::Compiled    = ();
$Apache::ASP::OLESupport  = 0;
$Apache::ASP::GlobalASA   = 0;
$Apache::ASP::Md5         = new MD5();
@Apache::ASP::Objects     = ('Application', 'Session', 'Response', 
			      'Server', 'Request');
$Apache::ASP::SessionCookieName = 'session-id';
%Apache::ASP::StatINC     = (); # used only if StatINC setting is on

# only if we support active objects on Win32 do we create
# the server object, which is in charge of object creation
eval 'require("Win32/OLE.pm")';
unless($@) {
    require("Win32/OLE.pm");
    $Apache::ASP::OLESupport = 1;
}

# now we support $main::Object syntax, so this is unnecessary
# export Objects for easier coding
#use Exporter;
#@Apache::ASP::ISA = qw(Exporter);
#@Apache::ASP::EXPORT_OK = @Apache::ASP::Objects;
#%Apache::ASP::EXPORT_TAGS = ('all' => \@EXPORT_OK);

sub handler {
    my($r) = @_;
    my $status = 200; # default OK

    # rarely happens, but just in case
    unless($r) {
	warn("no request object passed to ASP handler");
	return;
    }

    #X: fix the error checking please
    return(404) unless (-e $r->filename());

    # ASP object creation, a lot goes on in there!
    my($self) = new($r);

    #X: GLOBAL.ASA not supported yet, its lame
    # $self->ProcessGlobalASA(); 

    if(! $self->{errors} && $self->IsChanged()) {
	my($script) = $self->Parse();
	$self->Compile($script);

	# stat inc after a fresh compile since we might have 
	# some new symbols to register
	$self->StatINC() if $self->{stat_inc};
    }
    
    unless($self->{errors}) {
	$self->Execute();
    }
    
    # error processing
    if($self->{errors} && ($self->{debug} >= 2)) {
	$self->PrettyError();
    } elsif($self->{errors} && $self->{Response}{header_done}) {
	$self->{r}->print("<!-- Error -->");
    } elsif($self->{errors}) {
	$status = 500;
    }

    $self->Debug({'num errors' => $self->{errors}}) if $self->{debug};
    $self->DESTROY();
    undef $self; # make sure we free up all of self now    

    $status;
}

sub new {
    my($r) = @_;

    # like cgi, operate in the scripts directory
    chdir(File::Basename::dirname($r->filename()));
    my($basename) = File::Basename::basename($r->filename());

    # session timeout in seconds since that is what we work with internally
    my $session_timeout = $r->dir_config('SessionTimeout') ? 
	$r->dir_config('SessionTimeout') * 60 : 1200;
    
    # asp object is handy for passing state around
    my $self = bless { 
	app_start      => 0,  # set this if the application is starting
	'basename'     => $basename,

	buffering_on   => (defined $r->dir_config('BufferingOn')) ? $r->dir_config('BufferingOn') : 1, # buffer output on by default
	    
	# if this is set we are parsing ourself through cgi
	cgi_do_self        => $r->dir_config('CgiDoSelf') || 0, # parse self

	# this is the server path that the client responds to 
	cookie_path    => $r->dir_config('CookiePath') || '/',
	
	# these are set by the Compile routine
	compile_error  => '', 
	
	debug          => $r->dir_config('Debug') || 0,  # debug level
	errors         => 0,
	errors_output  => [],
	filename       => $r->filename(),
	id             => '', # parsed version of filename
	
	# where all the state and config files lie
	global         => $r->dir_config('Global') || '.',
	
	# refresh group by some increment smaller than session timeout
	# to withstand DoS, bruteforce guessing attacks
	# defaults to checking the group once every 2 minutes
	group_refresh  => (sprintf("%d", $session_timeout / 600) || 1) * 60,

	# assume we already chdir'd to where the file is
	mtime          => stat($basename)->mtime,  # better than -M
	
	# set this if you don't want an Application or Session object
	# available to your scripts
	no_session     => ((defined $r->dir_config('AllowSessionState')) ? (! $r->dir_config('AllowSessionState')) : 0),
	no_state       => $r->dir_config('NoState'),
	
	r              => $r, # apache request object 
	remote_ip      => $r->connection()->remote_ip(),
	session_start  => 0,  # set this if we have a new session beginning
	session_timeout => $session_timeout,
	session_serialize => $r->dir_config('SessionSerialize'),
	
	soft_redirect  => $r->dir_config('SoftRedirect'),
	stat_inc       => $r->dir_config('StatINC'),    

	# special objects for ASP app
	Application    => '',
	Internal       => '',
	Request        => '',
	Response       => '',
	Session        => '',
	Server         => ''
	};
    
    $self->{id} = $self->{filename};
    $self->{id} =~ s/\W/_/gso;
    
    $self->Debug('creating asp', $self) if $self->{debug};
    
    # make sure we have a cookie path config'd if we need one for state
    if(! $self->{no_session} && ! $self->{cookie_path}) {
	$self->Error("CookiePath variable not set in config file");
	$self->{cookie_path} = '/'; # safe default, apps still work
    }

    # must have global directory into which we put the state files
    $self->{global} || 
	$self->Error("global not set in config file");
    (-d $self->{global}) || 
	$self->Error("global path, $self->{global}, is not a directory");
    
    # initialize the big ASP objects now
    $self->InitObjects();

    $self;
}

sub DESTROY {
    my($self) = @_;
    my($k, $v);

    $self->Debug("destroying", {asp=>$self});

    # free file handles here.  mod_perl tends to be pretty clingy
    # to memory
    no strict 'refs';
    untie %{$self->{Application}};
    untie %{$self->{Internal}};
    untie %{$self->{Session}};

    while(($k, $v) = each %{$self}) {
	undef $self->{$k};
    }

    1;
}

sub InitObjects {
    my($self) = @_;

    # always create these
    $self->{Response} = &Apache::ASP::Response::new($self);
    $self->{Request}  = &Apache::ASP::Request::new($self);
    $self->{Server} = &Apache::ASP::Server::new($self);

    # cut out now before we get to the big objects
    return if ($self->{errors});

    # if no state has been config'd, then set up none of the 
    # state objects: Application, Internal, Session
    return $self if $self->{no_state};

    # create application object
    ($self->{Application} = &Apache::ASP::Application::new($self)) 
	|| $self->Error("can't get application state");
    $self->{debug} && 
	$self->Debug('created $Application', $self->{Application});
    
    # if we are tracking state, set up the appropriate objects
    if(! $self->{no_session}) {
	# tie to the application internal info
	my %Internal;
	tie(%Internal, 'Apache::ASP::State', $self,
	    'internal', 'server', O_RDWR|O_CREAT)
	    || $self->Error("can't tie to internal state");
	
	# Session state is dependent on internal state begin set first
	$self->{Internal} = \%Internal;
	$self->{Session} = &Apache::ASP::Session::new($self);    	
    } else {
	$self->{debug} && $self->Debug("no sessions allowed config");
    }
    
    $self;
}

# global.asa processes, whether or not there is a global.asa file.
# if there is not one, the code is left blank, and empty routines
# are filled in
#
sub ProcessGlobalASA {
    return if ($Apache::ASP::GlobalASA);
    my($self) = @_;

    $self->Debug("processing GlobalASA for $$") if $self->{debug};
    $Apache::ASP::GlobalASA = 1;

    my($filename) = "$self->{global}/GLOBAL.ASA";
    my($code) = $self->ReadFile($filename);
    $code =~ s/\<\/?script?.*?\>/\#script tag removed here/igs;
    
    # fill in code for undefined events
    for(@Apache::ASP::GlobalASARoutines) {
	next if($code =~ /sub $_/s);	   
	$code .= "\nsub $_ { }\n";
    }
    $self->Compile($code, 'GlobalASA'); 

    $self;
}

sub IsChanged {
    my($self) = @_;

    # do the StatINC if we are config'd for it
    # we return true if stat inc tells us that some
    # libraries had been changed, since a script is
    # new if the library is new under it.
    if($self->{stat_inc}) { 
	return(1) if $self->StatINC(); 
    }

    my $last_update = $Apache::ASP::Compiled{$self->{id}}->{mtime} || 0;
    ($self->{mtime} > $last_update) ? 1 : 0;
}        

sub Parse {
    my($self) = @_;
    my($script, $text, $perl);

    my($data) = $self->ReadFile($self->{'basename'});
    if($self->{cgi_do_self}) {
	$data =~ s/^(.*?)__END__//gso;
    }

    # there should only be one of these, rip it out
    $data =~ s/\<\%\@(.*?)\%\>//so; 
    $data .= "\n<%;%>\n"; # always end with some perl code for parsing.
    my(@out);
    while($data =~ s/^(.*?)\<\%(?:\s*\n)?(.*?)\s*\%\>//so) {
	($text, $perl) = ($1,$2);
	$perl =~ s/^\s+$//gso;
	$text =~ s/^\s$//gso;

	if($text) {
	    $text =~ s/\\/\\\\/gso;
	    $text =~ s/\'/\\\'/gso;
	    push(@out, "\'".$text."\'")
	}

	if($perl) {
	    # X:
	    # take out, since this might get someone in trouble
	    # should work on the objects for porting compatibility
	    # like a Collections class.
	    #
	    # PerlScript compatibility
	    if($perl =~ s/(\$.*?\(.*?\))\-\>item/$1/sgo) {
		$self->Debug
		    ("parsing out ->item for PerlScript ".
		     "compatibility from $perl"
		     );
	    }
	    
	    if($perl =~ /^\s*\=(.*)/o) {
		push(@out, '('.$1.')');
	    } else {
		if(@out) {
		    $script .= join
			("\n",
			 '',
			 '$main::Response->Write(',
			 join(".", @out),
			 ');',
			 ''
			 );
		    @out = ();
		}			 
		    
		# skip if the perl code is just a placeholder
		unless($perl eq ';') {
		    $script .= join
			("\n",
			 '',
			 '## CODE BEGIN ##',
			 $perl,
			 '## END ##',
			 ''
			 );
		}
	    }
	}
    }

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
    my($self, $script, $id, $no_cache) = @_;
    my($package);

    # if we don't cache the script, it will only be stored as temp,
    # and will be rewritten next no_cache script is compiled
    if($no_cache) {
	$package = "_NO_CACHE";
    } elsif($id) {
	$package = $id;
    } else {
	$package = $self->{id};
    }
    
    $self->Debug("compiling", 
		 {'package'=> $package, id=>$id, no_cache=>$no_cache}
		 );
    undef &{"Apache::ASP::Compiles::" . $package . "::handler"};

    my($eval) = 
	join("\n", 
	     "package Apache::ASP::Compiles::" . $package . ";" ,
	     'no strict;', 
	     '',
	     '# allow developers to place modules in global directory',
	     "use lib qw($self->{global});",
	     '',
	     '# aliases here ',
	     'sub exit { $main::Response->End(); } ',
	     '',
	     '# handler gets called from ASP perl handler to run code ',
	     'sub handler { ',
	     '  my($self, $routine) = @_; ',
	     '  $self = ""; ',
	     '',
	     '  if($routine && ($routine ne "handler")) { ',
	     '    return &$routine; ',
	     '  } ',
	     '',
	     '#######################################################',
	     '## Your ASP script has been parsed and inserted here !! ',
	     '#######################################################',
	     '',
	     $script,
	     '',
	     '#######################################################',
	     '## End script insert',
	     '#######################################################',
	     '',
	     '  $main::Response->End(); ',
	     '}',
	     '1;'
	     );

    eval $eval;
    my($rv) = (! $@);
    if($@) {
	$self->Error($@);
	$self->{compile_error} .= "\n$@\n";
    } else {
	$Apache::ASP::Compiled{$package}->{mtime}  = $self->{mtime};
    }
    $Apache::ASP::Compiled{$package}->{output} = $eval;	
    
    $rv;
}

sub Execute {
    my($self, $id, $routine) = @_;
    
    return if $self->{errors};
    $id ||= $self->{id};
    $routine ||= '';
    
    $self->Debug("executing", {id=>$id, routine=>$routine})
	if $self->{debug};
    
    my $package = "Apache::ASP::Compiles::".$id; 
    my $handler = \&{$package."::handler"};
    
    # alias $0 to filename
    my $filename = $self->{filename};
    local *0 = \$filename;

    # init objects
    my($object, $import_package);
    no strict 'refs';
    for $object (@Apache::ASP::Objects) {
	for $import_package ('main', $package) {
	    my $init_var = $import_package.'::'.$object;
	    ${$init_var} = $self->{$object};
	}
    }

    # set printing to Response object
    tie *RESPONSE, 'Apache::ASP::Response', $self->{Response};
    select(RESPONSE);

    # run the script now, then check for errors
    eval ' &{$handler}($self, $routine) ';  
    if($@ !~ /Apache\:\:exit/) { $self->Error($@); } 
    
    # so we don't interfere with the printing mechanism of 
    # other perl-handlers
    select(STDOUT); 

    # undef objects
    for $object (@Apache::ASP::Objects) {
	for $import_package ('main', $package) {
	    my $init_var = $import_package.'::'.$object;
	    undef $$init_var;
	}
    }

    my($rv) = (! $@);
    $rv;
}

sub PrettyError {
    my($self) = @_;
    my($r) = $self->{Response};

    $r->Clear();
    $r->{ContentType} = "text/html";
    $r->Write("\n\n");
    $r->Write("<pre>");
    
    $r->Write("Errors Output:\n");
    $r->Write($self->Escape(join("\n", @{$self->{errors_output}}, "\n")));
    
    $r->Write("Debug Output:\n");
    $r->Write($self->Escape(join("\n", @{$self->{debugs_output}}, "\n")));
    
    if($self->{compile_error}) {
	$r->Write("Compile Error:\n");
	$r->Write($self->Escape($self->{compile_error}) . "\n");
    }

    $r->Write("ASP to Perl Program:\n");
    my($lineno) = 1;
    for(split(/\n/, $Apache::ASP::Compiled{$self->{id}}->{output})) {
	$_ = $self->Escape($_);
	$r->Write($lineno++ . ": $_\n");
    }
    $r->Write("\n\n");
    $r->Write("</pre>");

    # help section
    $r->Write("<hr width=20% size=1>\n<font size=-1>");
    $r->Write("<i>If you can't help yourself, please send mail to ");
    my @emails;
    for(@Apache::ASP::Contacts) {
	push(@emails, "<a href=\"mailto:$_?Subject=Apache::ASP\">$_</a>");
    }
    $r->Write(join(' or ', @emails));
    $r->Write(" about your problem, including this output.</font>");

    $r->Flush();
	
    1;
}

sub Log {
    my($self, $msg) = @_;
    $msg =~ s/[\r\n]+/ \<\-\-\> /sg;
    $self->{r}->log_error("[asp] $msg");
}    

sub Error {
    my($self, $msg) = @_;
    
    my($package, $filename, $line) = caller;
    $msg .= ", $filename line $line";
    
    # error logging in $self
    $self->{errors}++;
    my $pretty_msg = $msg;
    $pretty_msg = $self->Escape($pretty_msg);
    $pretty_msg =~ s/\n/<br>/sg;

    push(@{$self->{errors_output}}, $msg);
    push(@{$self->{debugs_output}}, $msg);
    
    $self->Log("[error] $msg");
    
    1;
}   

sub Debug {
    # try to cut the overhead on sprinkling through code
    return unless $_[0]->{debug};
    
    my($self, $msg, $data) = @_;
    $data ||= '';
    $msg ||= '';

    if(ref $msg) {
	$data = $msg;
	$msg = '';
    }
	
    if($msg || $data) {
	my($debug) = $msg;
	if($data) {
	    $debug .= "... ";
	    for(sort keys %{$data}) {
		$debug .= "$_: $data->{$_}; ";
	    }
	}
	$self->Log("[debug] [$$] $debug");
	push(@{$self->{debugs_output}}, $debug);
    }
    
    1;
}

sub Print {
    my($self, $msg) = @_;
    $self->{r}->print($msg);
}

# combo get / set
sub SessionId {
    my($self, $id) = @_;

    #X: should we set the secure variable here? 
    if($id) {
	$self->{r}->header_out
	    ("Set-Cookie", 
	     "$Apache::ASP::SessionCookieName=$id; path=$self->{cookie_path}"
	     );
    } else {
	my($cookie) = $self->{r}->header_in("Cookie");
	$cookie ||= '';
	my(@parts) = split(/\;\s*/, $cookie);
	my(%cookie) = map { split(/\=/, $_)} @parts;
	
	$id = $cookie{$Apache::ASP::SessionCookieName};
	$self->Debug($id);
    }

    $id;
}

sub Secret {
    my($self) = @_;

    my $md5 = $Apache::ASP::Md5;
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

# Apache::StatINC didn't quite work right, so writing own
sub StatINC {
    my $self = shift;
    my $stats = 0;

    # include necessary libs, without nice error message
    for('Devel/Symdump.pm', 'Apache/Symbol.pm') {
	unless(require $_) {
	    $self->Error("You need $_ to use StatINC. ".
			 "Please download it from your nearest CPAN"
			 );
	}
    }
    
    while(my($key,$file) = each %INC) {
#	next if ($key =~ /Apache/); # can't reload Apache::* while using them
	next unless (-e $file); # sometimes there is a bad file in the %INC

#	local $^W = 0;

	my $mtime = stat($file)->mtime;

	# first time? assume unchanged, since this is our first loading
	unless(defined $Apache::ASP::Stat{$file}) { 
	    $self->StatRegister($key, $file, $mtime);
	    # just initialized a lib, so not changed	    
	    next;
	}

	if($mtime > $Apache::ASP::Stat{$file}) {
	    $self->Debug("reloading", {$key => $file});
	    $stats++; # count files we have reloaded

	    my $class = &Apache::Symbol::file2class($key);
	    my $sym = Devel::Symdump->new($class);

	    my $function;
	    for $function ($sym->functions()) { 
		my $code = \&{$function};
		next if $Apache::ASP::Codes{$code}{count} > 1;
#		$self->Debug("undef code $function: $code");
		&Apache::Symbol::undef($code);
		delete $Apache::ASP::Codes{$code};
	    }

	    # extract the lib, just incase our @INC went away
	    (my $lib = $file) =~ s/$key$//g;
	    push(@INC, $lib);

	    delete $INC{$key};
	    require $key || $self->Error("can't require/reload $key");

	    # update key now, sets mtime and new codes
	    $self->StatRegister($key, $file, $mtime);
	}
    }

    $stats;
}

sub StatRegister {
    my($self, $key, $file, $mtime) = @_;

    # keep track of times
    $Apache::ASP::Stat{$file} = $mtime; 
    
    # keep track of codes, don't undef on codes
    # with multiple refs, since these are exported
    my $class = &Apache::Symbol::file2class($key);
    my $sym = Devel::Symdump->new($class);
    my $function;
    for $function ($sym->functions()) {
	my $code = \&{$function};
	# don't update if we already have this code defined for this func.
	next if $Apache::ASP::Codes{$code}{funcs}{$function}; 

#	$self->Debug("code $code for $function");
	$Apache::ASP::Codes{$code}{count}++;
	$Apache::ASP::Codes{$code}{libs}{$key}++;
	$Apache::ASP::Codes{$code}{funcs}{$function}++;
    }

    1;
}

1;

# Request Object
package Apache::ASP::Request;

# quick AUTOLOAD lookup
%Apache::ASP::Request::Collections = 
    (
     Cookies => 1,
     Form => 1,
     QueryString => 1,
     ServerVariables => 1,
     );

sub new {
    my($r) = $_[0]->{r};
    my($self) = bless { asp=> $_[0]};
    my(%query, %form, %env, %cookies);
    
    %query = $r->args();
    $self->{'QueryString'} = \%query;

    %env = $r->cgi_env();
    $self->{'ServerVariables'} = \%env;

    # assign no matter what so Form is always defined
    if(($r->method() || '') eq "POST") {
	%form = $r->content();
    }
    $self->{'Form'} = \%form;

    # do cookies now
    my @parts = split(/;\s*/, ($r->header_in("Cookie") || ''));
    for(@parts) {	
	my($name, $value) = split(/\=/, $_, 2);
	$name = $self->Unescape($name);

	next if ($name eq $Apache::ASP::SessionCookieName);
	next if $cookies{$name};

	$cookies{$name} = ($value =~ /\=/) ? 
	    $self->ParseParams($value) : $self->Unescape($value);
    }
    $self->{Cookies} = \%cookies;

    $self;
}

sub DESTROY {}

sub AUTOLOAD {
    my($self, $index) = @_;
    my $AUTOLOAD = $Apache::ASP::Request::AUTOLOAD;

    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/o;

    # must match a valid collection
    unless($Apache::ASP::Request::Collections{$AUTOLOAD}) {
	$self->{asp}->Error("Collection $AUTOLOAD invalid for \$Request object");
	return;
    }
	    
    if(defined($index)) {
	$self->{$AUTOLOAD}{$index};
    } else {
	$self->{$AUTOLOAD};
    }
}

sub Cookies {
    my($self, $name, $key) = @_;

    if(! $name) {
	$self->{Cookies};
    } elsif($key) {
	$self->{Cookies}{$name}{$key};
    } else {
	# when we just have the name, are we expecting a dictionary or not
	my $cookie = $self->{Cookies}{$name};
	if(ref $cookie && wantarray()) {
	    return %$cookie;
	} else {
	    return $cookie;
	}
    }
}

sub ParseParams {
    my($self,$tosplit) = @_;
    my(@pairs) = split('&',$tosplit);
    my($param,$value,%params);

    foreach (@pairs) {
	($param,$value) = split('=');
	$param = $self->Unescape($param);
	$value = $self->Unescape($value);
	$params{$param} = $value;
    }

    \%params;
}

# unescape URL-encoded data
sub Unescape {
    my($self, $todecode) = @_;
    $todecode =~ tr/+/ /;       # pluses become spaces
    $todecode =~ s/%([0-9a-fA-F]{2})/pack("c",hex($1))/ge;
    return $todecode;
}

1;

# Response Object
package Apache::ASP::Response;
use Apache qw(exit);
use Carp qw(confess);

%Apache::ASP::Response::Members = 
    (
     Buffer => 1,
     ContentType => 1,
     Expires => 1,
     ExpiresAbsolute => 1,
     Status => 1,
     );

sub new {
    $, ||= '';

    return bless {
	asp => $_[0],
	buffer => '',
	Cookies => {},
	ContentType => 'text/html',
	header_buffer => '', 
	header_done => 0,
	Buffer => $_[0]->{buffering_on},
	r => $_[0]->{r}
	};
}

sub DESTROY {}; # autoload doesn't have to skip it

# allow for deprecated use of routines that should be direct member access
sub AUTOLOAD {
    my($self, $value) = @_;
    my %Members = %Apache::ASP::Response::Members; 
    my $AUTOLOAD = $Apache::ASP::Response::AUTOLOAD;

    $AUTOLOAD =~ /::([^:]*)$/o;
    $AUTOLOAD = $1;
    
    if($Members{$AUTOLOAD}) {
	$self->{asp}->Debug
	    (
	     "\$Response->$AUTOLOAD() deprecated.  Please access member ".
	     "directly with \$Response->{$AUTOLOAD} notation"
	     );
	$self->{$AUTOLOAD} = $value;
    } else {
	confess "Response::$AUTOLOAD not defined"; 
    }
}

sub AddHeader { $_[0]->{r}->header_out($_[1], $_[2]); }
sub AppendToLog { $_[0]->{asp}->Log($_[1]); }
*BinaryWrite = *Write; # someone needs to explain the difference to me
sub Clear { $_[0]->{buffer} = ''; }

sub Cookies {
    my($self, $name, $key, $value) = @_;
    $key ||= 'Value';
    $self->{Cookies}{$name}{$key} = $value;
}

sub End {
    my($self) = @_;

    # only at the end do we really know the length, don't pretend to know unless
    # we really do, that's why this is here and not in write
    unless($self->{header_done}) {
	$self->AddHeader('Content-Length', length($self->{buffer}));
    }

    # force headers out, though body could still be empty
    # every doc will therefore return at least a header
    $self->Write(); 
    $self->Flush();
    #    &Apache::exit('Apache::exit'); ## this die's, no good for now

    die('Apache::exit');
}

sub Flush {
    my($self) = @_;

    # if this is the first writing from the page, flush a newline, to 
    # get the headers out properly
    if(! $self->{header_done}) {
	$self->{header_done}++;
	$self->{asp}->Debug("sending headers", {response => $self});
	$self->{r}->content_type($self->{ContentType});

	# do page status
	if(defined $self->{Status}) {
	    $self->{r}->status($self->{Status});
	}
	    
	# do the expiration time
	if(defined $self->{Expires}) {
	    my $ttl = $self->{Expires};
	    $self->{r}->header_out('Expires', &HTTP::Date::time2str(time()+$ttl));
	    $self->{asp}->Debug("expires in $self->{Expires}");
	} elsif(defined $self->{ExpiresAbsolute}) {
	    my $date = $self->{ExpiresAbsolute};
	    my $time = &HTTP::Date::str2time($date);
	    if(defined $time) {
		$self->{r}->header_out('Expires', &HTTP::Date::time2str($time));
	    } else {
		die("Response->ExpiresAbsolute(): date format $date not accepted");
	    }
	}

	# do cookies, try our best to emulate cookie collections
	my($cookies, $cookie);
	if($cookies = $self->{'Cookies'}) {
	    my $cookie_name;
	    for $cookie_name (keys %{$cookies}) {
		# skip key used for session id
		if($Apache::ASP::SessionCookieName eq $cookie_name) {
		    die("You can't use $cookie_name for a cookie name ".
			"since it is reserved for session management"
			);
		}

		my($k, $v, @data, $header, %dict, $is_ref, $cookie, $old_k);

		$cookie = $cookies->{$cookie_name};
		unless(ref $cookie) {
		    $cookie->{Value} = $cookie;
		} 
		$cookie->{Path} ||= $self->{asp}{cookie_path};

		for $k (sort keys %$cookie) {
		    $v = $cookie->{$k};
		    $old_k = $k;
		    $k = lc $k;

		    if($k eq 'secure') {
		    	$data[4] = 'secure';
		    } elsif($k eq 'domain') {
			$data[3] = "$k=$v";
		    } elsif($k eq 'value') {
			# we set the value later, nothing for now
		    } elsif($k eq 'expires') {
			my $time;
			# only the date form of expires is portable, the 
			# time vals are nice features of this implementation
			if($v =~ /^\d+$/) { 
			    # if expires is a perl time val
			    if($v > time()) { 
				# if greater than time now, it is absolute
				$time = $v;
			    } else {
				# small, relative time, add to time now
				$time = $v + time();
			    }
			} else {
			    # it is a string format, PORTABLE use
			    $time = &HTTP::Date::str2time($v);
			}

			my $date = &HTTP::Date::time2str($time);
			$self->{asp}->Debug("setting cookie expires", 
					    {from => $v, to=> $date}
					    );
			$v = $date;
			$data[1] = "$k=$v";
		    } elsif(grep($k eq $_, 'path', 'domain')) {
			$data[2] = "$k=$v";
		    } else {
			if($cookie->{Value} && ! (ref $cookie->{Value})) {
			    # if the cookie value is just a string, its not a dict
			} else {
			    # cookie value is a dict, add to it
			    $cookie->{Value}{$old_k} = $v;
			}			
		    } 
		}

		my $server = $self->{asp}{Server}; # for the URLEncode routine
		if($cookie->{Value} && (! ref $cookie->{Value})) {
		    $cookie->{Value} = $server->URLEncode($cookie->{Value});
		} else {
		    my @dict;
		    while(($k, $v) = each %{$cookie->{Value}}) {
			push(@dict, $server->URLEncode($k) 
			     . '=' . $server->URLEncode($v));
		    }
		    $cookie->{Value} = join('&', @dict);
		} 
		$data[0] = $server->URLEncode($cookie_name) . 
		    "=$cookie->{Value}";

		# have to clean the data now of undefined values, but
		# keeping the position is important to stick to the Cookie-Spec
		my @cookie;
		for(0..4) {	
			next unless $data[$_];
			push(@cookie, $data[$_]);
		}		
		my $cookie_header = join('; ', @cookie);
		$self->{r}->header_out("Set-Cookie", $cookie_header);
		$self->{asp}->Debug({cookie_header=>$cookie_header});
	    }
	}

	# avoid the cgi circularity here with printing to STDOUT
	my $buffer = $self->{buffer};
	$self->{buffer} = '';

	if($self->{header_buffer}) {
	    # we have taken in cgi headers
	    $self->{r}->send_cgi_header($self->{header_buffer} . "\n");
	    $self->{header_buffer} = '';
	} else {	
	    $self->{r}->send_http_header();
	}

	$self->{buffer} = $buffer;
    }

    $self->{r}->print($self->{buffer});
    $self->{buffer} = '';

    1;
}

# use the apache internal redirect?  Thought that would be counter
# to portability, but is still something to consider
sub Redirect {
    my($self, $location) = @_;

    $self->{asp}->Debug('redirect called', {location=>$location});
    $self->{r}->header_out('Location', $location);
    $self->{r}->status(302);
    $self->Clear();

    # if we have soft redirects, keep processing page after redirect
    unless($self->{asp}{soft_redirect}) {
	$self->End(); 
    } else {
	$self->{asp}->Debug("redirect is soft");
    }

    1;
}

sub Write {
    my($self, @send) = @_;
    return unless $send[0];

    # work on the headers while the header hasn't been done
    # and while we don't have anything in the buffer yet
    if(! $self->{header_done} && ! $self->{buffer}) {
	# join and split in case we have 2 headers hiding in one
	my $send = join("\n", @send); 

	# -1 to catch the null at the end maybe
	my @headers = split(/\n/, $send, -1); 

	# first do status line
	my $status = $headers[0];
	if($status =~ m|HTTP/\d\.\d\s*(\d*)|o) {
	    $self->{Status} = $1; 
	    shift @headers;
	}

	while(@headers) {
	    my $out = shift @headers;
	    next unless $out; # skip the blank that comes after the last newline

	    if($out =~ /^[^\s]+\: /) { # we are a header
		$self->{header_buffer} .= "$out\n";
	    } else {
		unshift(@headers, $out);
		last;
	    }
	}
	
	# if there is anything left, they are not headers so prepare
	# it for adding to the buffer
	if(@headers) {
	    my $buffer = join("\n", @headers);
	    @send = ($buffer);
	} else {
	    # everything was a header, exit now
	    return 1;
	}
    }

    # add @send to buffer
    if($send[0]) {
	$self->{buffer} .= join($,, @send);
    }

    # do we flush now?  not if we are buffering
    if(! $self->{Buffer} && ! $self->{buffer}) {
	# we test for whether anything is in the buffer since
	# this way we can keep reading headers before flushing
	# them out
	$self->Flush();
    } 

    1;
}
*write = *Write;

# alias printing to the response object
sub TIEHANDLE { my($class, $self) = @_; $self; }
*PRINT = *Write;
sub PRINTF {
    my($self, @args) = @_;   
    my $output = sprintf @args;
    $self->Write($output);
}

1;

# Server Object
package Apache::ASP::Server;

sub new {
    bless {asp => $_[0]};
}

sub CreateObject {
    my($self, $name) = @_;
    my($asp) = $self->{asp};

    unless($Apache::ASP::OLESupport) {
	die "OLE-active objects not supported for this platform, ".
	    "try installing Win32::OLE";
    }

    unless($name) {
	die "no object to create";
    }

    Win32::OLE->new($name);
}

# shamelessly ripped off from CGI.pm, by Lincoln D. Stein.
sub URLEncode {
    my($self, $toencode) = @_;
    $toencode=~s/([^a-zA-Z0-9_\-.])/uc sprintf("%%%02x",ord($1))/eg;
    return $toencode;
}

# shamelessly ripped off from CGI.pm, by Lincoln D. Stein.
sub HTMLEncode {
    my($self,$toencode) = @_;
    return undef unless defined($toencode);
    $toencode=~s/&/&amp;/g;
    $toencode=~s/\"/&quot;/g;
    $toencode=~s/>/&gt;/g;
    $toencode=~s/</&lt;/g;
    return $toencode;
}

1;

# Application Object
package Apache::ASP::Application;
use Fcntl qw( O_RDWR O_CREAT );

sub new {
    my($asp) = @_;
    my(%self);

    unless(
	   tie(
	       %self,'Apache::ASP::State', $asp, 
	       'application', 'server', 
	       O_RDWR|O_CREAT)
	   )
    {
	$asp->Error("can't tie to application state");
	return;
    }

    bless \%self;
}

sub Lock { $_[0]->{_LOCK} = 1; }
sub UnLock { $_[0]->{_LOCK} = 0; }    
    
1;

# Session Object
package Apache::ASP::Session;
use Apache;

sub new {
    my($asp) = @_;
    my($id, $state);
    
    # apply a user lock to internal, free it at the end of
    # session creation, this is an optimization.  this also
    # serializes requests to the session manager
    $asp->{Internal}{_LOCK} = 1;

    if($id = $asp->SessionId()) {
	$state = Apache::ASP::State::new($asp, $id);
	$state->UserLock() if $asp->{session_serialize};
	$asp->Debug("new session state", $state);

	my $internal;
	if($internal = $asp->{Internal}{$id}) {
	    # user is authentic, since the id is in our internal hash
	    if($internal->{timeout} > time()) {
		# session not expired
		$asp->Debug("session not expired",{timeout=>$internal->{timeout}});
		$state->Get()
		    || $asp->Error("session state get failed");
	    } else {
		# expired, get & reset
		$asp->Debug("session timed out, clearing");
		$state->Init()
		    || $asp->Error("session state init failed");
		$asp->{Internal}{$id} = {};
	    }
	} else {
	    # never seen before, someone's hacking

	    # X: make sure to clean up Internal when garbage
	    # collecting the session states

	    # slow them down so provable security
	    # if we had wire speed authentication, we'd
	    # have a real security issue, otherwise, the md5
	    # hash session key is 2^128 in size, so would 
	    # take arguably too long for someone to try all the 
	    # sessions before they get garbage collected
	    sleep(1); 
	    $state->Init()
		|| $asp->Error("session state init failed");
	    $asp->{Internal}{$id} = {};

	    # wish we could do more than just log the error
	    # but proxying + nat prevents us from securing via ip address
	    $asp->Log("[security] session id $id asked for by ip $asp->{remote_ip}");
	}
    } else {
	# give user new session id
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
	$state = &Apache::ASP::State::new($asp, $id);
	$state->Set()
	    || $asp->Error("session state set failed");
    }

    if($state) {
	# refresh timeout by internal refresh, or default refresh
	my $internal = $asp->{Internal}{$id};
	my $refresh_timeout = $internal->{refresh_timeout};
	$refresh_timeout ||= $asp->{session_timeout};
	$internal->{timeout} = time() + $refresh_timeout;
	$asp->{Internal}{$id} = $internal;

	# release lock now
	$asp->{Internal}{_LOCK} = 0;
    } else {
	$asp->Error("can't get state for id $id");
	$asp->{Internal}{_LOCK} = 0;
	return;
    }

    my(%self); 
    tie %self, 'Apache::ASP::Session', 
    {
	state=>$state, 
	asp=>$asp, 
	id=>$id,
    };
    $asp->Debug("tieing session", \%self);

    # cleanup timed out sessions, from current group
    my($group_id) = "GroupId" . $state->GroupId();
    my($group_check) = $asp->{Internal}{$group_id} || 0;
    $asp->Debug("group check at: $group_check, time:" . time());
    if($group_check < time()) {
	my $ids = $state->GroupMembers();
#	$asp->Debug("group members: " . join(",", @$ids));
	for(@{$ids}) {
	    my $timeout = $asp->{Internal}{$_}{timeout} || 0;

	    # only delete sessions that have timed out
	    next unless ($timeout < time());

	    unless($timeout) {
		# no timeout, log it, as it is an error, 
		# and repair the session timeout
		$asp->Log("no timeout found for id:$_; group:$group_id");
		$asp->{Internal}{$_} = {
		    'timeout' => time() + $asp->{session_timeout}
		};
		next;
	    }	

	    if($id eq $_) {
		$asp->Error("trying to delete self, id: $id");
		next;
	    }

	    my($member_state) = Apache::ASP::State::new($asp, $_);
	    if(my $count = $member_state->Delete()) {
		$asp->Debug("deleting session", {
		    session_id => $_, 
		    files_deleted => $count,
		});
	    } else {
		$asp->Error("can't delete session id: $_");
		next;
	    }
	    delete $asp->{Internal}{$_};
	}

	# next refresh one minute away
	$asp->{Internal}{$group_id} = time() + $asp->{group_refresh};
    }

    bless \%self;
}	

sub TIEHASH { 
    my($package, $self) = @_;
    bless $self;
}       

# stub so we don't have to test for it in autoload
sub DESTROY {
    my $self = shift;
    $self->{state}->UserUnLock() if $self->{asp}{session_serialize};
    untie $self->{state};
    undef $self->{state};
} 

# don't need to skip DESTROY since we have it here
# return if ($AUTOLOAD =~ /DESTROY/);
sub AUTOLOAD {
    my $self = shift;
    my $AUTOLOAD = $Apache::ASP::Session::AUTOLOAD;
    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/o;
    $self->{state}->$AUTOLOAD(@_);
}

sub FETCH {
    my($self, $index) = @_;

    if($index eq '_ID') {
	$self->{id};
    } elsif($index eq '_TIMEOUT') {
	my($refresh) = $self->{asp}{Internal}{$self->{id}}{refresh_timeout};
	$refresh ||= $self->{asp}{session_timeout};
	$refresh / 60;
    } else {
	$self->{state}->FETCH($index);
    }
}

sub STORE {
    my($self, $index, $value) = @_;

    if($index eq '_TIMEOUT') {
	my($minutes) = $value;
	my($internal_session) = $self->{asp}{Internal}{$self->{id}};
	$internal_session->{refresh_timeout} = $minutes * 60;
	$internal_session->{timeout} = time() + $minutes * 60;
	$self->{asp}{Internal}{$self->{id}} = $internal_session;
    } else {
	$self->{state}->STORE($index, $value);
    }
}	

sub SessionID {
    my($self) = @_;
    $self->{_ID};
}

sub Timeout {
    my($self, $minutes) = @_;

    if($minutes) {
	$self->{_TIMEOUT} = $minutes;
    } else {
	$self->{_TIMEOUT};
    }
}    

sub Abandon {
    my($self) = @_;
    $self->Timeout(-1);
    %{$self} = ();
}

1;

package Apache::ASP::State;
use Fcntl qw(:flock O_RDWR O_CREAT);
#use Fcntl qw( O_RDWR O_CREAT );

# X: LOCK FILE
# About locking, we use a separate lock file from the SDBM files
# generated because locking directly on the SDBM files occasionally
# results in sdbm store errors.  This is less efficient, than locking
# to the db file directly, but having a separate lock file works for now.
#
sub new {
    my($asp, $id, $group, $permissions) = @_;

    unless($id) {
	$asp->Error("no id: $id passed into new State");
	return;
    }

    # default group is first character of id, simple hashing
    unless($group) {
	$id =~ /^(..)/;
	$group = $1;
    }

    unless($group) {
	$asp->Error("no group defined for id $id");
	return;
    }

    my($state_dir) = "$asp->{global}/.state";
    my($group_dir) = "$state_dir/$group";
    my($lock_file) = "$group_dir/$id.lock";

    my $self = bless {
	asp=>$asp,
	dbm => '', 
	'dir' => $group_dir,
	'ext' => ['dir', 'pag', 'lock'],	    
	id => $id, 
	file => "$group_dir/$id",
	group => $group, 
	group_dir => $group_dir,
	locked => 0,
	lock_file => $lock_file,
	lock_file_fh => $lock_file,
	state_dir => $state_dir,
	user_lock => 0,
    };

    # create state directory
    unless(-d $state_dir) {
	mkdir($state_dir, 0755) 
	    || $self->{asp}->Error("can't create state dir $state_dir");
    }

    # create group directory
    unless(-d $group_dir) {
	if(mkdir($group_dir, 0755)) {
	    $self->{asp}->Debug("creating group dir $group_dir");
	} else {
	    $self->{asp}->Error("can't create group dir $group_dir");	    
	}
    }    

    # open lock file now, and once for performance
    $self->OpenLock();

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

    $self->Set() || return;
    $self->{dbm}->CLEAR();

    $self;
}

sub Do {
    my($self, $permissions) = @_;

    # make sure we got all the right stuff
    unless($self->{id} && $self->{group} && (defined $permissions)) {
	$self->{asp}->Error("something is missing in doing state ".
			    "id: $self->{id}; group: $self->{group}; ".
			    "permissions: $permissions"
			    );
	return;
    }
    
    # Tie to MLDBM Database
    # set the params for MLDBM use, and tie to db, possible bug
    # fix to mixing settings for other app uses.
    # save the settings first and restore them afterwards
    # so developer can use MLDBM for other things.
    #
    my @temp = ($MLDBM::UseDB, $MLDBM::Serializer);
    $MLDBM::UseDB = "SDBM_File";
    $MLDBM::Serializer = 'Data::Dumper';
    $self->{dbm} = &MLDBM::TIEHASH('MLDBM', $self->{file}, $permissions, 0644);
    ($MLDBM::UseDB, $MLDBM::Serializer) = @temp;    

    if($self->{dbm}) {
	# used to have locking code here
    } else {
	$self->{asp}->Error("Can't tie to file $self->{file}!! \n".
			    "Make sure you have the permissions on the \n".
			    "directory set correctly, and that your \n".
			    "version of Data::Dumper is up to date. \n".
			    "Also, make sure you have set Global to \n".
			    "to a good directory in the config file."
			    );
    }

    $self->{dbm};
}

sub Delete {
    my($self) = @_;
    my $count = 0;

    unless($self->{file}) {
	$self->{asp}->Error("no state file to delete");
	return;
    }

    # we open the lock file when we new, so must close
    # before unlinking it
    $self->CloseLock();
    
    # manually unlink state files
    for(@{$self->{'ext'}}) {
	my $unlink_file = "$self->{file}.$_";
	next unless (-e $unlink_file);

	if(unlink($unlink_file)) {
	    $count++;
#	    $self->{asp}->Debug("deleted state file $unlink_file");
	} else {
	    $self->{asp}->Error("can't unlink state file $unlink_file"); 
	    return;
	}
    }

    $count;
}

sub GroupId {
    my($self) = @_;
    $self->{group};
}

sub GroupMembers {
    my($self) = @_;
    local(*DIR);
    my(%ids, @ids);

    unless(-d $self->{group_dir}) {
	$self->{asp}->Error("no group dir:$self->{group_dir} to get group from");
	return;
    }

    opendir(DIR, $self->{group_dir}) 
	|| $self->{asp}->Error("opening group $self->{group_dir} failed: $!");
    for(readdir(DIR)) {
	$_ =~ /(.*)\.[^\.]+$/;
	next unless $1;
	$ids{$1}++;
    }
    # need to explicitly close directory, or we get a file
    # handle leak on Solaris
    closedir(DIR); 
    @ids = keys %ids;

    \@ids;
}

sub DESTROY {
    my $self = shift;
    untie $self->{dbm} if $self->{dbm};
#    undef $self->{dbm};
    $self->UnLock();
    $self->CloseLock();
}

# don't need to skip DESTROY since we have it defined
# return if ($AUTOLOAD =~ /DESTROY/);
sub AUTOLOAD {
    my $self = shift;
    my $AUTOLOAD = $Apache::ASP::State::AUTOLOAD;
    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/o;

    my $value;
    if($self->{user_lock}) {
	# if it is locked by the user, no need to 
	# lock item by item
	$value = $self->{dbm}->$AUTOLOAD(@_);
    } else {
	$self->WriteLock();
	my $value = $self->{dbm}->$AUTOLOAD(@_);
	$self->UnLock();
    }

    $value;
}

sub TIEHASH {
    my($type) = shift;
    bless &new(@_), $type;
}

sub FETCH {
    my($self, $index) = @_;
    my $value;

    if($index eq '_FILE') {
	$value = $self->{file};
    } else {
	# again, no need to lock if locked by user
	if($self->{user_lock}) {
	    $value = $self->{dbm}->FETCH($index);
	} else {
	    $self->ReadLock();
	    $value = $self->{dbm}->FETCH($index);
	    $self->UnLock();
	}
    }

    $value;
}

sub STORE {
    my($self, $index, $value) = @_;

    # Debugging SDBM store errors
    # my $print_value = ref($value) ? join(",", %{$value}) : $value;
    # $self->{asp}->Log("$self->{id} storing $index=>$print_value");    

    # allow control of the locking mechanism through the tie'd interface
    # we do this to help the implementation of user locking
    # for esp. $Application which requires it in the API,
    # and for $Internal, which sees a lot of action in Session creation
    #
    # at writing, user locks take precedence over internal locks
    # and internal locks will not be used while user locks are 
    # in effect.  this is an optimization.
    #
    if($index eq '_LOCK') {
	if($value) {
	    $self->UserLock();
	} else {
	    $self->UserUnLock();
	}
    } else {
	$self->{dbm}->STORE($index, $value);
    }
}

# the +> mode open a read/write w/clobber file handle.
# the clobber is useful, since we don't have to create
# the lock file first
sub OpenLock {
    my($self) = @_;
    no strict 'refs';
    open($self->{lock_file_fh}, "+>$self->{lock_file}") 
	|| $self->{asp}->Error("Can't open $self->{lock_file}: $!");
}

sub CloseLock { 
    no strict 'refs';
    close($_[0]->{lock_file_fh}); 
}

use Carp qw(confess);

sub ReadLock {
    my($self) = @_;
    no strict 'refs';
    my $file = $self->{lock_file_fh};

    if($self->{locked}) {
	$self->{asp}->Debug("already read locked $file");
	1;
    } else {
	$self->{locked} = 1;
	flock($file, LOCK_SH)
	    || $self->{asp}->Error("Can't read lock $file: $!");    
    }
}

sub WriteLock {
    my($self) = @_;
    no strict 'refs';
    my $file = $self->{lock_file_fh};

    if($self->{locked}) {
	$self->{asp}->Debug("already write locked $file");
	1;
    } else {
	$self->{locked} = 1;
	flock($file, LOCK_EX)
	    || $self->{asp}->Error("can't write lock $file: $!");    
    }
}

sub UnLock {
    my($self) = @_;
    no strict 'refs';
    my $file = $self->{lock_file_fh};
    
    if($self->{locked}) {
	$self->{locked} = 0;
	#	$self->{asp}->Debug("unlocking $file");

	# locks only work when they were locked before, but we don't
	# care, so long as the file is unlocked at the end of it all
	# so, no testing
	flock($file, LOCK_UN);
    } else {
	# don't debug about this, since we'll always get some
	# of these since we are a bit over zealous about unlocking
	# better to unlock to much than too little
	#	$self->{asp}->Debug("file $file already unlocked");
	1;
    }
}

sub UserLock {
    my $self = $_[0];
    
    unless($self->{user_lock}) {
	$self->{user_lock} = 1;
	$self->{asp}->Debug("user locking $self->{lock_file}");
	$self->WriteLock();
    }
}

sub UserUnLock {
    my $self = $_[0];
    
    if($self->{user_lock}) {
	$self->{user_lock} = 0;
	$self->{asp}->Debug("user unlocking $self->{lock_file}");
	$self->UnLock();
    }
}   

1;

# this package emulates an Apache request object with a CGI backend
package Apache::ASP::CGI;

sub do_self {
    my($r) = &init($0, @ARGV);
    $r->dir_config('CgiDoSelf', 1);
    &Apache::ASP::handler($r);
}

sub init {
    my($filename, @args) = @_;
    $filename ||= $0;
    
    for('CGI.pm', 'Class/Struct.pm') {
	next if require $_;
	die("can't load the $_ library.  please make sure you installed it");
    }
    
    &Class::Struct::struct( 'Apache::ASP::CGI::connection' => 
			   { 'remote_ip' => "\$" }
			   );    

    &Class::Struct::struct( 'Apache::ASP::CGI' => 
			   {
			       'cgi'       =>    "\$",
			       'connection'=>'Apache::ASP::CGI::connection',
			       'content_type' => "\$",
			       'dir_config'=>    "\%",
			       'env'       =>    "\%",
			       'filename'  =>    "\$",
			       'header_in' =>    "\%",
			       'header_out'=>    "\%",
			       'method'    =>    "\$",
			   }
			   );

    # create struct
    my $self = new();
    my $cgi = CGI->new({@args});

    $self->cgi($cgi);
    $self->filename($filename);
    $self->header_in('Cookie', $ENV{HTTP_COOKIE});
    $self->connection->remote_ip($cgi->remote_host());
    $self->dir_config('Global') || $self->dir_config('Global', '.');
    $self->method($cgi->request_method());

    $self->{env} = \%ENV;
    $self->env('SCRIPT_NAME') || $self->env('SCRIPT_NAME', $filename);

    $self;
}
    
sub status { $_[0]->header_out('status', $_[1]); }
sub cgi_env { %{$_[0]->env} ; }

sub send_http_header {
    my($self) = @_;
    my($k, $v, $header);
    
    $header = "Content-Type: " .$self->content_type()."\n";
    my $headers = $self->header_out();
    while(($k, $v) = each %$headers) {
	$header .= "$k: $v\n";
    }
    $header .= "\n";
 	
    $self->print($header);
}

sub send_cgi_header {
    my($self, $header) = @_;

    my(@left);
    for(split(/\n/, $header)) {
	my($name, $value) = split(/\:\s*/, $_, 2);
	if($name =~ /content-type/i) {
	    $self->content_type($value);
	} else {
	    push(@left, $_);
	}
    }

    $self->print(join("\n", @left, ''));
    $self->send_http_header();
}

sub print { shift; print STDOUT @_; }

sub args {
    my($self) = @_;
    my %params;

    my @params = $self->cgi()->param();
    for (@params) {
	$params{$_} = $self->cgi()->param($_);
    }

    %params;
}
*content = *args;

sub log_error {
    my($self, @args) = @_;
    print STDERR @args, "\n";
}

1;

__END__

=head2 INSTALLATION

Apache::ASP installs easily using the make or nmake commands as
shown below.  Otherwise, just copy ASP.pm to $PERLLIB/site/Apache

 > perl Makefile.PL
 > make 
 > make test
 > make install

 * use nmake for win32

=head2 CONFIG

Use with Apache.  Copy the /eg directory from the ASP installation 
to your Apache document tree and try it out!  You have to put

 AllowOverride All

in your <Directory> config section to let the .htaccess file in the 
/eg installation directory do its work.

If you want a STARTER config file, just look at the .htaccess
file in the /eg directory.

Here is a Location directive that you would put in a *.conf Apache 
configuration file.  It describes the ASP variables that you 
can set.  Don't set the optional ones if you don't want, the 
defaults are fine...

 ##ASP##PERL##APACHE##UNIX##WINNT##ASP##PERL##APACHE##NOT##IIS##ASP##
 ## INSERT INTO Apache *.conf file, probably access.conf
 ##ASP##PERL##APACHE##ACTIVE##SERVER##PAGES##SCRIPTING##FREE##PEACE##

 <Location /asp/>    

 ###########################################################
 ## mandatory 
 ###########################################################

 # Generic apache directives to make asp start ticking.
 SetHandler perl-script
 PerlHandler Apache::ASP

 # Global
 # ------
 # Must be some writeable directory.  Session and Application
 # state files will be stored in this directory, and 
 # as this directory is pushed onto @INC, you will be 
 # able to "use" and "require" files in this directory.
 #
 PerlSetVar Global /tmp  
	
 ###########################################################
 ## optional flags 
 ###########################################################

 # CookiePath
 # ----------
 # Url root that client responds to by sending the session cookie.
 # If your asp application falls under the server url "/ASP", 
 # then you would set this variable to /ASP.  This then allows
 # you to run different applications on the same server, with
 # different user sessions for each application.
 #
 PerlSetVar CookiePath /   

 # AllowSessionState
 # -----------------
 # Set to 0 for no session tracking, 1 by default
 # If Session tracking is turned off, performance improves,
 # but the $Session object is inaccessible.
 #
 PerlSetVar AllowSessionState 1    

 # SessionTimeout
 # --------------
 # Session timeout in minutes (defaults to 20)
 #
 PerlSetVar SessionTimeout 20 

 # Debug
 # -----
 # 1 for server log debugging, 2 for extra client html output
 # Use 1 for production debugging, use 2 for development.
 # Turn off if you are not debugging.
 #
 PerlSetVar Debug 2	

 # BufferingOn
 # -----------
 # default 1, if true, buffers output through the response object.
 # $Response object will only send results to client browser if
 # a $Response->Flush() is called, or if the asp script ends.  Lots of 
 # output will need to be flushed incrementally.
 # 
 # If false, 0, the output is immediately written to the client,
 # CGI style.
 #
 # I would only turn this off if you have a really robust site,
 # since error handling is poor, if your asp script errors
 # after sending only some text.
 #
 PerlSetVar BufferingOn 1

 # StatINC
 # -------
 # default 0, if true, reloads perl libraries that have changed
 # on disk automatically for ASP scripts.  If false, the www server
 # must be restarted for library changes to take effect.
 #
 # A known bug is that any functions that are exported, e.g. confess 
 # Carp qw(confess), will not be refreshed by StatINC.  To refresh
 # these, you must restart the www server.  
 #
 PerlSetVar StatINC 1

 # SessionSerialize
 # ----------------
 # default 0, if true, locks $Session for duration of script, which
 # serializes requests to the $Session object.  Only one script at
 # a time may run, with sessions allowed.
 # 
 # Serialized requests to the session object is the Microsoft ASP way, 
 # but is dangerous in a production environment, where there is risk
 # of long-running or run-away processes.  If these things happen,
 # a session may be locked for an indefinate period of time.  The
 # terrible STOP button, would be easy prey here, where a user
 # keeps hitting stop and reload, and the scripts execute one at a time
 # until finished.  A run-away process would keep the session locked
 # until server restart.
 #
 PerlSetVar SessionSerialize 0

 # SoftRedirect
 # ------------
 # default 0, if true, a $Response->Redirect() does not end the 
 # script.  Normally, when a Redirect() is called, the script
 # is ended automatically.  SoftRedirect 1, is a standard
 # way of doing redirects, allowing for html output after the 
 # redirect is specified.
 #
 SoftRedirect 0

 </Location>

 ##ASP##PERL##APACHE##UNIX##WINNT##ASP##PERL##APACHE##NOT##IIS##ASP##
 ## END INSERT
 ##ASP##PERL##APACHE##ACTIVE##SERVER##PAGES##SCRIPTING##!#MICROSOFT##

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

Notice that your perl code blocks can span any html.  The for loop
above iterates over the html without any special syntax.

=head1 The Object Model

The beauty of the ASP Object Model is that it takes the
burden of CGI and Session Management off the developer, 
and puts them in objects accessible from any
ASP page.  For the perl programmer, treat these objects
as globals accesible from anywhere in your ASP application.

 Currently the Apache::ASP object model supports the following:

 Object		--	Function
 ------			--------
 $Session	--	session state
 $Response	--	output
 $Request	--	input
 $Application	--	application state
 $Server	--	OLE support + misc

These objects, and their methods are further defined in the 
following sections.

=head2 $Session Object

The $Session object keeps track of user + web client state, in
a persistent manner, making it relatively easy to develop web 
applications.  The $Session state is stored accross HTTP connections,
in SDBM_Files in the Global directory, and will persist across
server restarts.

The user's session is referenced by a 32-byte md5-hashed cookie, and can 
be considered secure from session_id guessing, or session hijacking.
When a hacker fails to guess a session, the system times out for a
second, and with 2**128 (3.4e38) keys to guess, a hacker won't be 
guessing an id any time soon.  Compare the 32-byte key with Miscrosoft 
ASP implementation which is only 16 bytes.

If an incoming cookie matches a timed out or non-existent session,
a new session is created with the incoming id.  If the id matches a
currently active session, the session is tied to it and returned.
This is also similar to Microsoft's ASP implementation.

The $Session ref is a hash ref, and can be used as such to store data
as in: 

 $Session->{count}++;	# increment count by one
 %{$Session} = ();	# clear $Session data

The $Session object state is implemented through MLDBM & SDBM_File,
and a user should be aware of MLDBM's limitations.  Basically, 
you can read complex structures, but not write them, directly:

 $data = $Session->{complex}{data};      # Read ok.
 $Session->{complex}{data} = $data;      # Write NOT ok.
 $Session->{complex} = {data => $data};  # Write ok, all at once.

Please see MLDBM for more information on this topic.
$Session can also be used for the following methods and properties:

=over

=item $Session->SessionID()

SessionID property, returns the id number for the current session,
which is exchanged between the client and the server as a cookie.

=item $Session->Timeout($minutes)

Timeout property, if minutes is defined, sets this session's 
default timeout, else returns the current session timeout.  
If a user session is inactive for the full
timeout, the user's session is destroyed by the system.
No one can access the session after it times out, and the system
garbage collects it eventually.

=item $Session->Abandon()

The abandon method times out the session immediately.  All Session
data is cleared in the process, just as when any session times out.

=back

=head2 $Response Object

This object manages the output from the ASP Application and the 
client's web browser.  It does store state information like the 
$Session object but does have a wide array of methods to call.

=over

=item $Response->{Buffer}

Default 1, when TRUE sends output from script to client only at
the end of processing the script.  When 0, response is not buffered,
and client is sent output as output is generated by the script.

=item $Response->{ContentType} = "text/html"

Sets the MIME type for the current response being sent to the client.
Sent as an HTTP header.

=item $Response->{Expires} = $time

Sends a response header to the client indicating the $time 
in SECONDS in which the document should expire.  A time of 0 means
immediate expiration.  The header generated is a standard
HTTP date like: "Wed, 09 Feb 1994 22:23:32 GMT".

=item $Response->{ExpiresAbsolute} = $date

Sends a response header to the client with $date being an absolute
time to expire.  Formats accepted are all those accepted by 
HTTP::Date::str2time(), e.g.

 "Wed, 09 Feb 1994 22:23:32 GMT"       -- HTTP format
 "Tuesday, 08-Feb-94 14:15:29 GMT"     -- old rfc850 HTTP format

 "08-Feb-94"         -- old rfc850 HTTP format    (no weekday, no time)
 "09 Feb 1994"       -- proposed new HTTP format  (no weekday, no time)

 "Feb  3  1994"      -- Unix 'ls -l' format
 "Feb  3 17:03"      -- Unix 'ls -l' format

=item $Response->AddHeader($name, $value)

Adds a custom header to a web page.  Headers are sent only before any
text from the main page is sent, so if you want to set a header
after some text on a page, you must turn BufferingOn.

=item $Response->AppendToLog($message)

Adds $message to the server log.

=item $Response->BinaryWrite($data)

Writes binary data to a page for use by client objects.
Could someone explain this to me?  This currently does
nothing more than a Write($data), since binary data can
be in a scalar.

=item $Response->Clear()

Erases buffered ASP output.

=item $Response->Cookies($name,$key,$value) (alpha)

Sets the key or attribute of cookie with name $name to the value $value.
If $key is not defined, then the Value of the cookie is assumed.
ASP CookiePath is assumed to be / in these examples.

 $Response->Cookies("Test Name", "", "Test Value"); 
   [... results in ...]
 Set-Cookie: Test+Name=Test+Value path=/            

 $Response->Cookies("Test", "data1", "test value");     
 $Response->Cookies("Test", "data2", "more test");      
 $Response->Cookies("Test", "Expires", &HTTP::Date::time2str(time() + 86400))); 
 $Response->Cookies("Test", "Secure", 1);               
 $Response->Cookies("Test", "Path", "/");
 $Response->Cookies("Test", "Domain", "host.com");
   [... results in ...]
 Set-Cookie: Test=data1=test+value&data2=more+test; expires=Wed, 09 Feb 1994 22:23:32 GMT; path=/; domain=host.com; secure 

Because this is perl, you can (NOT PORTABLE) reference the cookies
directly through hash notation.  The same 5 commands above could be compressed to:

 $Response->{Cookies}{Test} = { 
	Secure	=> 1, 
	Value	=> {data1 => 'test value', data2 => 'more test'},
	Expires	=> 86400, # not portable shortcut, see above for proper use
	Domain	=> 'host.com',
	Path    => '/'
	};

and the first command would be:

 # you don't need to use hash notation when you are only setting 
 # a simple value
 $Response->{Cookies}{'Test Name'} = 'Test Value'; 

For more information on Cookies, please go to the source at:
http://home.netscape.com/newsref/std/cookie_spec.html

=item $Response->End()

Sends result to client, and immediately exits script.
Automatically called at end of script, if not already called.

=item $Response->Flush()

Sends buffered output to client and clears buffer.

=item $Response->Redirect($url)

Sends the client a command to go to a different url $url.  
Script immediately ends.

=item $Response->{Status} = $status

Sets the status code returned by the server.  Can be used to
set messages like 500, internal server error

=item $Response->Write($data)

Write output to the HTML page.  <%=$data%> syntax is shorthand for
a $Response->Write($data).  All final output to the client must at
some point go through this method.

=back

=head2 $Request Object

The request object manages the input from the client brower, like
posts, query strings, cookies, etc.  Normal return results are values
if an index is specified, or a collection / perl hash ref if no index 
is specified.  WARNING, the latter property is not supported in 
Activeware's PerlScript, so if you use the hashes returned by such
a technique, it will not be portable.

 # A normal use of this feature would be to iterate through the 
 # form variables in the form hash...

 $form = $Request->Form();
 for(keys %{$form}) {
	$Response->Write("$_: $form->{$_}<br>\n");
 }

 # Please see the eg/server_variables.htm asp file for this 
 # method in action.

=over

=item $Request->ClientCertificate()

Not implemented.

=item $Request->Cookies($name, $key) (alpha)

Returns the value of the Cookie with name $name.  If a $key is
specified, then a lookup will be done on the cookie as if it were
a query string.  So, a cookie set by:

 Set-Cookie: test=data1=1&data2=2

would have a value of 2 returned by $Request->Cookies('test', 'data2').

If no name is specified, a hash will be returned of cookie names 
as keys and cookie values as values.  If the cookie value is a query string, 
it will automatically be parsed, and the value will be a hash reference to 
these values.

=item $Request->Form($name)

Returns the value of the input of name $name used in a form
with POST method.  If $name is not specified, returns a ref to 
a hash of all the form data.

=item $Request->QueryString($name)

Returns the value of the input of name $name used in a form
with GET method, or passed by appending a query string to the end of
a url as in http://someurl.com/?data=value.  
If $name is not specified, returns a ref to a hash of all the query 
string data.

=item $Request->ServerVariables($name)

Returns the value of the server variable / environment variable
with name $name.  If $name is not specified, returns a ref to 
a hash of all the server / environment variables data.  The following
would be a common use of this method:

 $env = $Request->ServerVariables();
 # %{$env} here would be equivalent to the cgi %ENV in perl.

=back

=head2 $Application Object

Like the $Session object, you may use the $Application object to 
store data across the entire life of the application.  Every
page in the ASP application always has access to this object.
So if you wanted to keep track of how many visitors there where
to the application during its lifetime, you might have a line
like this:

 $Application->{num_users}++

The Lock and Unlock methods are used to prevent simultaneous 
access to the $Application object.

=over

=item $Application->Lock()

Locks the Application object for the life of the script, or until
UnLock() unlocks it, whichever comes first.  When $Application
is locked, this gaurantees that data being read and written to it 
will not suddenly change on you between the reads and the writes.

This and the $Session object both lock automatically upon
every read and every write to ensure data integrity.  This 
lock is useful for concurrent access control purposes.

Be careful to not be too liberal with this, as you can quickly 
create application bottlenecks with its improper use.

=item $Application->UnLock()

Unlocks the $Application object.  If already unlocked, does nothing.

=back

=head2 $Server Object

The server object is that object that handles everything that the other
objects don't.  The best part of the server object for Win32 users is 
the CreateObject method which allows developers to create instances of
ActiveX components, like the ADO component.

=over

=item $Server->{ScriptTimeout} = $seconds

Will not be implemented, please see the Apache Timeout configuration
option, normally in httpd.conf.  

=item $Server->CreateObject($program_id)

Allows use of ActiveX objects on Win32.  This routine returns
a reference to an Win32::OLE object upon success, and nothing upon
failure.  It is through this mechanism that a developer can 
utilize ADO.  The equivalent syntax in VBScript is 

 Set object = Server.CreateObject(program_id)

For further information, try 'perldoc Win32::OLE' from your
favorite command line.

=item $Server->HTMLEncode($string)

Returns an HTML escapes version of $string. &, ", >, <, are each
escapes with their HTML equivalents.  Strings encoded in this nature
should be raw text displayed to an end user, as HTML tags become 
escaped with this method.

=item $Server->MapPath($virtual_directory);

Not implemented

=item $Server->URLEncode($string)

Returns the URL-escaped version of the string $string. +'s are substituted in
for spaces and special characters are escaped to the ascii equivalents.
Strings encoded in this manner are safe to put in url's... they are especially
useful for encoding data used in a query string as in:

 $data = $Server->URLEncode("test data");
 $url = "http://localhost?data=$data";

 $url evaluates to http://localhost?data=test+data, and is a 
 valid URL for use in anchor <a> tags and redirects, etc.

=back

=head1 EXAMPLES

Use with Apache.  Copy the ./eg directory from the ASP installation 
to your Apache document tree and try it out!  You have to put

 AllowOverride All

in your <Directory> config section to let the .htaccess file in the 
/eg installation directory do its work.  

IMPORTANT (FAQ): Make sure that the web server has write access to 
that directory.  Usually a 

 chmod -R 0777 eg

will do the trick :)

=head1 FAQ

=over

=item How do I get things I want done?!

If you find a problem with the module, or would like a feature added,
please mail support, as listed below, and your needs will be
promptly and seriously considered, then implemented.

=item What is the state of Apache::ASP?  Can I publish a web site on it?

Apache::ASP has been production ready since v.02.  Work being done
on the module is on a per-need basis, with the goal being to eventually
have the ASP API completed, with full portability to ActiveState's PerlScript
and MKS's PScript.  If you can suggest any changes to facilitate these
goals, your comments are welcome.

=item I am getting a tie or MLDBM / state error message, what do I do?

Make sure the web server or you have write access to the eg directory,
or to the directory specified as Global in the config you are using.
Default for Global is the directory the script is in (e.g. '.'), but should
be set to some directory not under the www server's document root,
for security reasons, on a production site.

Usually a 

 chmod -R -0777 eg

will take care of the write access issue for initial testing purposes.

Failing write access being the problem, try upgrading your version
of Data::Dumper and MLDBM, which are the modules used to write the 
state files.

=item How do I access the ASP Objects in general?

All the ASP objects can be referenced through the main package with
the following notation:

 $main::Response->Write("html output");

This notation can be used from anywhere in perl.  Only in your main
ASP script, can you use the normal notation:

 $Response->Write("html output");

=item Can I print() in ASP?

Yes.  You can print() from anywhere in an ASP script as it aliases
to the $Response->Write() method.  However, this method is not 
portable (unless you can tell me otherwise :)

=back

=head1 SEE ALSO

perl(1), mod_perl(3), Apache(3), MLDBM(3), HTTP::Date(3), CGI(3),
Win32::OLE(3)

=head1 NOTES

Many thanks to those who helped me make this module a reality.
Whoever said you couldn't do ASP on UNIX?  Kudos go out to:

 :) Doug MacEachern, for moral support and of course mod_perl
 :) Ryan Whelan, for boldly testing on Unix in its ASP's early infancy
 :) Lupe Christoph, for his immaculate and stubborn testing skills
 :) Bryan Murphy, for being a PerlScript wiz.
 :) Francesco Pasqualini, for bringing ASP to CGI.
 :) Michael Rothwell, for his love of Session hacking.

=head1 SUPPORT

Please send any questions or comments to the Apache modperl mailing
list at modperl@apache.org or to me at chamas@alumni.stanford.org.

=head1 COPYRIGHT

Copyright (c) 1998 Joshua Chamas.
All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=cut








