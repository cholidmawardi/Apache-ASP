#!perl -w

=head1 NAME

Apache::ASP - Active Server Pages for Apache (all platforms)

=head1 SYNOPSIS

=begin text

	SetHandler perl-script
	PerlHandler Apache::ASP
	PerlSetVar Global /tmp # must be some writeable directory

=end text

=cut Documentation continues at the end of the module.

package Apache::ASP;

sub VERSION { .02; }

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

# use Storable;
# problem with Storable with MLDBM, when referencing empty undefined
# value, hangs, and module reloads.
# $MLDBM::Serializer = "Storable"; # faster than using Data::Dumper
#
$MLDBM::Serializer = "Data::Dumper";

%Apache::ASP::Compiled     = ();
$Apache::ASP::OLESupport   = 0;
$Apache::ASP::GlobalASA    = 0;
$Apache::ASP::Md5          = new MD5();
@Apache::ASP::Objects      = ('Application', 'Session', 'Response', 
			      'Server', 'Request', 'Internal');

# these define the default routines that get parsed out of the 
# GLOBAL.ASA file
@Apache::ASP::GlobalASARoutines = 
    (
     "Application_OnStart", "Application_OnEnd", 
     "Session_OnStart", "Session_OnEnd"
     );

# only if we support active objects on Win32 do we create
# the server object, which is in charge of object creation
eval 'require("Win32/OLE.pm")';
unless($@) {
    require("Win32/OLE.pm");
    $Apache::ASP::OLESupport = 1;
}

sub handler {
    my($r) = @_;

    #X: fix the error checking please
    return(FORBIDDEN) unless (-e $r->filename());
    # $self->$IsAsp() || return(FORBIDDEN);

    # ASP object creation, a lot goes on in there!
    my($self) = new($r);

    #X: GLOBAL.ASA not supported yet, its lame
    # $self->ProcessGlobalASA(); 

    if(! $self->{errors} && $self->IsChanged()) {
	my($script) = $self->Parse();
	$self->Compile($script);
    }
    
    unless($self->{errors}) {
	$self->Execute();
	$status = OK;
    }
    
    # error processing
    if($self->{errors} && ($self->{debug} >= 2)) {
	$self->PrettyError();
	$status = OK;
    } elsif($self->{errors}) {
	$status = SERVER_ERROR;
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

    # asp object is handy for passing state around
    my $self = bless { 
	app_start      => 0,  # set this if the application is starting
	buffering_on   => (defined $r->dir_config(BufferingOn)) ?
	    $r->dir_config(BufferingOn) : 1, # buffer output on by default

	# this is the server path that the client responds to 
	cookie_path    => $r->dir_config(CookiePath) || '/',

	# these are set by the Compile routine
	compile_error  => '', 

	debug          => $r->dir_config(Debug),  # debug level
	errors         => 0,
	errors_output  => [],
	filename       => $r->filename(),
	id             => '', # parsed version of filename
	
	# where all the state and config files lie
	global         => $r->dir_config(Global),

	mtime          => stat($r->filename())->mtime,  # better than -M

	# set this if you don't want an Application or Session object
	# available to your scripts
	no_session     => 0,

	r              => $r, # apache request object 
	remote_ip      => $r->connection()->remote_ip(),
	session_start  => 0,  # set this if we have a new session beginning
	session_timeout => ($r->dir_config(SessionTimeout) * 60) || 1200,

	# special objects for ASP app
	Application    => '',
	Internal       => '',
	Request        => '',
	Response       => '',
	Session        => '',
	Server         => ''
	};
    
    $self->{id} = $self->{filename};
    $self->{id} =~ s/\W/_/gs;
    
    # no_session is true if the user has explicitly disallowed session state
    $self->{no_session} = (defined $r->dir_config('AllowSessionState')) ?
	(! $r->dir_config('AllowSessionState')) : 0;

    $self->Debug('creating asp', $self) if $self->{debug};
    
    # make sure we have a cookie path config'd if we need one for state
    if(! $self->{no_session} && ! $self->{cookie_path}) {
	$self->Error("CookiePath variable not set in config file");
	$self->{cookie_path} = '/'; # safe default, apps still work
    }

    # must have global directory into which we put the state files
    $self->{global} || $self->Error("global not set in config file");
    (-d $self->{global}) 
	|| $self->Error("global path, $self->{global}, is not a directory");
    
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
    untie %{$self->{Application}};
    untie %{$self->{Internal}};
    untie %{$self->{Session}};

    while(($k, $v) = each %{$self}) {
	undef $self->{$k};
    }
    
}

sub InitObjects {
    my($self) = @_;

    # always create these
    $self->{Request}  = &Apache::ASP::Request::new($self);
    $self->{Response} = &Apache::ASP::Response::new($self);

    # cut out now before we get to the big objects
    return if ($self->{errors});

    ($self->{Application} = &Apache::ASP::Application::new($self)) 
	|| $self->Error("can't get application state");
    
    # if we are tracking state, set up the appropriate objects
    if(! $self->{no_session}) {
	# tie to the application internal info
	tie(%{$self->{Internal}}, 'Apache::ASP::State', $self,
	    'internal', 'server', O_RDWR|O_CREAT)
	    || $self->Error("can't tie to internal state");
	
	# Session state is dependent on Application State begin set first
	$self->{Session} = &Apache::ASP::Session::new($self);    	
    } else {
	$self->Debug("no sessions allowed config");
    }
    
    $self->{Server} = &Apache::ASP::Server::new($self);
    $self->Debug("created server object", {server=>$self->{Server}});
    
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
    ($self->{mtime} > $Apache::ASP::Compiled{$self->{id}}->{mtime}) ? 1 : 0;
}        

sub Parse {
    my($self) = @_;
    my($script, $text, $perl);

    my($data) = $self->ReadFile($self->{filename});
    $data =~ s/\<\%\@(.*?)\%\>//s; # there should only be one of these
    while($data =~ s/^(.*?)\<\%\s*(.*?)\%\>//s) {
	($text, $perl) = ($1,$2);
	$perl =~ s/^\s+$//gs;
	$text =~ s/^\s$//gs;

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
	    # PerlScript compatibility
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
	     '',
	     '# allow developers to place modules in global directory',
	     "use lib qw($self->{global});",
#	     'use Apache();',
	     '',
	     '# aliases here ',
	     'sub exit { $Response->End(); } ',
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
	     '  # if $Response->End() is not already called, do so now',
	     '  $Response->End(); ',
	     '}',
	     '1;'
	     );

    Apache->untaint($eval);
    
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
    $id = $id ? $id :$self->{id};
    $routine = $routine ? $routine : '';
    
    $self->Debug("executing", {id=>$id, routine=>$routine})
	if $self->{debug};
    
    my $package = "Apache::ASP::Compiles::".$id; 
    my $handler = \&{$package."::handler"};
    
    # init objects
    for(@Apache::ASP::Objects) {
	my($object) = $package . '::' . $_;
	$$object = $self->{$_};
    }

    eval ' &{$handler}($self, $routine) ';  
    if($@ !~ /Apache\:\:exit/) { $self->Error($@); } 
    
    # clean up objects
    for(@Apache::ASP::Objects) {
	my($object) = $package . '::' . $_;
	undef $$object;
    }

    my($rv) = (! $@);
    $rv;
}

sub PrettyError {
    my($self) = @_;
    my($r) = $self->{Response};

    $r->Clear();
    $r->ContentType("text/html");
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
    push(@{$self->{errors_output}}, $msg);
    push(@{$self->{debugs_output}}, $msg);
    
    $self->Log("[error] $msg");
    
    1;
}   

sub Debug {
    # try to cut the overhead on sprinkling through code
    return unless $_[0]->{debug};
    
    my($self, $msg, $data) = @_;
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
	$self->Log("[debug] $debug");
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

# Request Object
package Apache::ASP::Request;

sub new {
    my($r) = $_[0]->{r};
    my($self) = bless {};
    my(%query, %form, %env);
    
    %query = $r->args();
    $self->{'QueryString'} = \%query;

    %env = $r->cgi_env();
    $self->{'ServerVariables'} = \%env;

    # assign no matter what so Form is always defined
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

# Response Object
package Apache::ASP::Response;
use Apache qw(exit);

sub new {
    return bless {
	asp => $_[0],
	buffer => '',
	header_done => 0,
	is_buffered => $_[0]->{buffering_on},
	r => $_[0]->{r}
	};
}
    
sub Write {
    my($self, $send) = @_;

    $self->{buffer} .= $send;
    unless($self->{is_buffered}) {
	$self->Flush();
    } else {
#	$self->{asp}->Debug("buffering");
    }

    1;
}

sub AppendToLog {
    my($self, $msg) = @_;
    $self->{asp}->Log($msg);
}

sub AddHeader {
    my($self, $name, $value) = @_;
    $self->{r}->header_out($name, $value);
}

sub Buffer {
    my($self, $value) = @_;
    $self->{is_buffered} = $value;
}

sub Clear {
    my($self) = @_;
    $self->{buffer} = '';
}

sub ContentType {
    my($self, $type) = @_;
    $self->{r}->header_out('Content-Type', $type);
}

# X: do relative times
sub Expires {
    my($self, $ttl) = @_;
    #X: how do we handle non 0 ttl's?
    $self->{r}->no_cache() if ($ttl == 0);
}

# use the apache internal redirect?  Thought that would be counter
# to portability, but is still something to consider
sub Redirect {
    my($self, $location) = @_;

    $self->{asp}->Debug('redirect called', {location=>$location});
    $self->{r}->header_out('Location', $location);
    $self->{r}->status(302);
    $self->Clear();
    $self->End(); # we should assume this page is done now, right?

    1;
}

sub Status {
    my($self, $status) = @_;
    $self->{r}->status($status);
}

sub Flush {
    my($self) = @_;

    # if this is the first writing from the page, flush a newline, to 
    # get the headers out properly
    if(! $self->{header_done}) {
	$self->{asp}->Debug("sending headers", {response => $self});
	unless($self->{r}->content_type) {
		$self->{asp}->Debug("setting content-type to text/html");
		$self->{r}->content_type("text/html");
	}
	
	$self->{r}->send_http_header();
	$self->{header_done}++;
    }

#    $self->{asp}->Debug("flushing buffer");
    $self->{r}->print($self->{buffer});
    $self->{buffer} = '';
    1;
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
1;

# Server Object
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

    unless($Apache::ASP::OLESupport) {
	$self->{asp}->Error("OLE-active objects not supported for this platform, ".
			    "try installing Win32::OLE"
			    );
	return;
    }

    unless($name) {
	$asp->Error("no object to create");
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

# Application Object
package Apache::ASP::Application;
use Fcntl qw( O_RDWR O_CREAT );

sub new {
    my($asp) = @_;
    my(%self);

    unless(tie(%self, 'Apache::ASP::State', $asp, 'application', 
	       'server', O_RDWR|O_CREAT))
    {
	$asp->Error("can't tie to application state");
	return;
    }

    bless \%self;
}

sub DESTROY { 
    my($self) = @_;   
    untie $self;
}

1;

# Session Object
package Apache::ASP::Session;
use Apache;

sub new {
    my($asp) = @_;
    my($id, $state, $internal);
    
    if($id = $asp->SessionId()) {
	$state = Apache::ASP::State::new($asp, $id);
	$asp->Debug("new session state", $state);

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
	    # but proxying + nat prevents up from securing via ip address
	    $asp->Log("[security] session id $id asked for ".
		      "by ip $asp->{remote_ip}"
		      );
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
	$internal = $asp->{Internal}{$id};
	my($refresh_timeout) = $internal->{refresh_timeout} ?
	    $internal->{refresh_timeout} : $asp->{session_timeout};
	$internal->{timeout} = time() + $refresh_timeout;
	$asp->{Internal}{$id} = $internal;
    } else {
	$asp->Error("can't get state for id $id");
	return;
    }

    my(%self); 
    tie %self, 'Apache::ASP::Session', {state=>$state, asp=>$asp, id=>$id};
    $asp->Debug("tieing session", \%self);

    # cleanup timed out sessions, from current group
    my($group_id) = "GroupId" . $state->GroupId();
    my($group_check) = $asp->{Internal}{$group_id};
    $asp->Debug("group check at: $group_check, time:" . time());
    if($group_check < time()) {
	$ids = $state->GroupMembers();
#	$asp->Debug("group members: " . join(",", @$ids));
	for(@{$ids}) {
	    my($timeout) = $asp->{Internal}{$_}{timeout};
	    unless($timeout) {
		$asp->Error("no timeout found for id:$_; group:$group_id");
		next;
	    }	

	    # only delete sessions that have timed out
	    next unless ($timeout < time());

	    if($id eq $_) {
		$asp->Error("trying to delete self, id: $id");
		next;
	    }

	    $asp->Debug("deleting session id: $_");
	    my($member_state) = Apache::ASP::State::new($asp, $_);
	    unless($member_state->Delete()) {
		$asp->Error("can't delete session id: $_");
		next;
	    }
	    undef $asp->{Internal}{$_};
	}

	# next refresh one minute away
	$asp->{Internal}{$group_id} = time() + 60;
    }

    bless \%self;
}	

sub TIEHASH { 
    my($package, $self) = @_;
    bless $self;
}       

sub AUTOLOAD {
    return if ($AUTOLOAD =~ /DESTROY/);
    my($self) = shift;

#    $self->{asp}->Debug("autoloading session", $self);
    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/i;
    $self->{state}->$AUTOLOAD(@_);
}

sub FETCH {
    my($self, $index) = @_;

#    $self->{asp}->Debug("session fetch $index");
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

#    $self->{asp}->Debug("session store $index=>$value");
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
use Fcntl qw( O_RDWR O_CREAT );

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
    my $self = bless {
	asp=>$asp,
	id => $id, 
	file => "$group_dir/$id",
	group => $group, 
	group_dir => $group_dir,
	state_dir => $state_dir
	};

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
    
    # create state directory
    my($state_dir) = $self->{state_dir};
    unless(-d $state_dir) {
	mkdir($state_dir, 0755) 
	    || $self->{asp}->Error("can't create state dir $state_dir");
    }

    # create group directory
    my($group_dir) = $self->{group_dir};
    unless(-d $group_dir) {
	mkdir($group_dir, 0755)
	    || $self->{asp}->Error("can't create group dir $group_dir");
    }    
    $self->{dir} = $group_dir;

    # tie to file
    $self->{dbm} = &MLDBM::TIEHASH('MLDBM', $self->{file}, $permissions, 0666);
    $self->{dbm} || $self->{asp}->Error("can't tie to file $self->{file}");

    $self->{dbm};
}

sub Delete {
    my($self) = @_;

    unless($self->{file}) {
	$self->{asp}->Error("no state file to delete");
	return;
    }
    
    # manually unlink state files, i would use tie for this, but don't know how
    for('.dir', '.pag') {
	unless(unlink("$self->{file}$_")) {
	    $self->{asp}->Error("can't unlink state file $self->{file}$_");	
	    return;
	}
	$self->{asp}->Debug("deleted state file $self->{file}$_");
    }

    1;
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
	|| $self->{asp}->Error("opening group dir:$self->{group_dir} failed");
    for(readdir(DIR)) {
	$_ =~ /(.*)\.[^\.]+$/;
	next unless $1;
	$ids{$1}++;
    }
    @ids = keys %ids;

    \@ids;
}

sub TIEHASH {
    my($type) = shift;
    bless &new(@_), $type;
}

sub AUTOLOAD {
    return if ($AUTOLOAD =~ /DESTROY/);
    my($self) = shift;

#    $self->{asp}->Debug("autoloading state", $self);
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

=head2 INSTALLATION

Apache::ASP installs easily using the make or nmake commands as
shown below.  Otherwise, just copy ASP.pm to $PERLLIB/site/Apache

=begin text

	> perl Makefile.PL
	> make 
	> make install

	* use nmake for win32

=end text

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

=begin text 

###########################################################
## INSERT INTO Apache *.conf file, probably access.conf
###########################################################

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

</Location>

###########################################################
## END INSERT
###########################################################

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
burden of CGI and Session Management off the developer, 
and puts them in objects accessible from any
ASP page.  For the perl programmer, treat these objects
as globals accesible from anywhere in your ASP application.

Currently the Apache::ASP object model supports the following:

=begin text

	Object		--	Function
	------			--------
	$Session	--	session state
	$Response	--	output
	$Request	--	input
	$Application	--	application state
	$Server		--	! not yet implemented !

=end text

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

=begin text

	$Session->{count}++;	# increment count by one
	%{$Session} = ();	# clear $Session data

=end text

The $Session object state is implemented through MLDBM & SDBM_File,
and a user should be aware of MLDBM's limitations.  Basically, 
you can read complex structures, but not write them, directly:

=begin text

	$data = $Session->{complex}{data};      # Read ok.
	$Session->{complex}{data} = $data;      # Write NOT ok.
	$Session->{complex} = {data => $data};  # Write ok, all at once.

=end text

Please see MLDBM for more information on this topic.
$Session can also be used for the following methods and properties:

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

=head2 $Response Object

This object manages the output from the ASP Application and the 
client's web browser.  It does store state information like the 
$Session object but does have a wide array of methods to call.

=item $Response->Buffer($boolean)

When set to true, output to client is buffered.  Defaults to false.

=item $Response->ContentType($content_type)

Sets the MIME content type of the current response.

=item $Response->Cookies($name, $key, $value);

Not implemented.

=item $Response->Expires($time)

Not implemented.

=item $Response->ExpiresAbsolute($date)

Not implemented.

=item $Response->Status($status)

Sets the status code returned by the server.  Can be used to
set messages like 500, internal server error

=item $Response->AddHeader($name, $value)

Adds a custom header to a web page.  Headers are sent only before any
text from the main page is sent, so if you want to set a header
after some text on a page, you must turn BufferingOn.

=item $Response->AppendToLog($message)

Adds $message to the server log.

=item $Response->BinaryWrite($data)

Not implemented.

=item $Response->Clear()

Erases buffered ASP output.

=item $Response->End()

Sends result to client, and immediately exits script.
Automatically called at end of script, if not already called.

=item $Response->Flush()

Sends buffered output to client and clears buffer.

=item $Response->Redirect($url)

Sends the client a command to go to a different url $url.  
Script immediately ends.

=item $Response->Write($data)

Write output to the HTML page.  <%=$data%> syntax is shorthand for
a $Response->Write($data).  All final output to the client must at
some point go through this method.

=head2 $Request Object

The request object manages the input from the client brower, like
posts, query strings, cookies, etc.  Normal return results are values
if an index is specified, or a collection / perl hash ref if no index 
is specified.  WARNING, the latter property is not supported in 
Activeware's PerlScript, so if you use the hashes returned by such
a technique, it will not be portable.

=begin text

	# A normal use of this feature would be to iterate through the 
	# form variables in the form hash...

	$form = $Request->Form();
	for(keys %{$form}) {
		$Response->Write("$_: $form->{$_}<br>\n");
	}

	# Please see the eg/server_variables.htm asp file for this 
	# method in action.

=end text

=item $Request->ClientCertificate()

Not implemented.

=item $Request->Cookies($index)

Not implemented.

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

=begin text

	$env = $Request->ServerVariables();
	# %{$env} here would be equivalent to the cgi %ENV in perl.

=end text

=head2 $Application Object

Like the $Session object, you may use the $Application object to 
store data across the entire life of the application.  Every
page in the ASP application always has access to this object.
So if you wanted to keep track of how many visitors there where
to the application during its lifetime, you might have a line
like this:

=begin text

	$Application->{num_users}++

=end text

The Lock and Unlock methods are used to prevent simultaneous 
access to the $Application object.

=item $Application->Lock()

Not implemented.

=item $Application->UnLock()

Not implemented.

=head2 $Server Object

Not implemented.

=head1 EXAMPLES

Use with Apache.  Copy the /eg directory from the ASP installation 
to your Apache document tree and try it out!  You have to put

AllowOverride All

in your <Directory> config section to let the .htaccess file in the 
/eg installation directory do its work.

=head1 SEE ALSO

perl(1), mod_perl(3), Apache(3)

=head1 NOTES

Many thanks to those who helped me make this module a reality.
Whoever said you couldn't do ASP on UNIX?  Kudos go out to:

=begin text

	:) Doug MacEachern, for moral support and of course mod_perl
	:) Ryan Whelan, for boldly testing on Unix in its ASP's early infancy
	:) Lupe Christoph, for his immaculate and stubborn testing skills

=end text

=head1 AUTHOR

Please send any questions or comments to Joshua Chamas
at chamas@alumni.stanford.org

=head1 COPYRIGHT

Copyright (c) 1998 Joshua Chamas.
All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=cut








