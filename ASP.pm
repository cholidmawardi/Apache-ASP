#!/usr/local/bin/perl

# For documentation for this module, please see the end of this file
# or try `perldoc Apache::ASP`

package Apache::ASP;
$VERSION = 1.91;

use MLDBM;
use SDBM_File;
use Data::Dumper;
use Fcntl qw(:flock O_RDWR O_CREAT);
use MD5;
use HTTP::Date;
use Carp qw(confess cluck);

use strict;
no strict qw(refs);
use vars qw($LOADED $COUNT $VERSION %includes $StatINCReady $StatINCInit 
	    %NetConfig %LoadedModules %LoadModuleErrors 
	    %Compiled $OLESupport %StatINC %Codes %Includes 
	    %CompiledIncludes $SessionCookieName $SessionIDLength
	    $DefaultStateDB $DefaultStateSerializer
	    $MD5 @Objects $Register %ScriptSubs %XSLT
	    $ServerID
	   );

#use integer; # don't use screws up important numeric logic

$MD5 = new MD5();
@Objects = ('Application', 'Session', 'Response', 'Server', 'Request');
$SessionCookieName = 'session-id';
$SessionIDLength = 32;
$DefaultStateDB = 'SDBM_File';
$DefaultStateSerializer = 'Data::Dumper';

# ServerID creates a unique identifier for the server
$MD5->add($$.rand().time().(-M('..')||'').(-M('/')||''));
$ServerID = substr($MD5->hexdigest, 0, 16);

# X: not thread safe for now since $r changes between handler and register_cleanup
# hash of Apache $r request keys to Apache::ASP values
# hopefully this will work in threaded context
# we need to keep ASP state around for lookup with $r for 
# $r->register_cleanup
#$Apache::ASP::Register = undef;
#@Apache::ASP::Cleanup  = ();

# DEFAULT VALUES
$Apache::ASP::SessionTimeout = 1200;
$Apache::ASP::StateManager   = 10;
$Apache::ASP::StartTime      = time();

%Apache::ASP::LoadModuleErrors = 
  (
   'Filter' => 
   "Apache::Filter was not loaded correctly for using SSI filtering.  ".
   "If you don't want to use filtering, make sure you turn the Filter ".
   "config option off whereever it's being used",

   Clean => undef,
   
   CreateObject => 
   'OLE-active objects not supported for this platform, '.
   'try installing Win32::OLE',
   
    Gzip =>
   'Compress::Zlib is needed to make gzip content-encoding work, '.
   'If you want to use this feature, get yourself the latest '.
   'Compress::Zlib from CPAN. ',
   
   HiRes => undef,

   MailAlert => undef,
   
#   OrderCollections => 'Ordered collections require the Tie::IxHash '.
#   'to be installed, which provides ordered perl hashes',

   SendMail => "No mailing support",
   
   StateDB => 
   'cannot load StateDB '.
   'must be a valid perl module with a db tied hash interface '.
   'such as: SDBM_File (default), or DB_File',
   
   StateSerializer =>
   'cannot load StateSerializer '.
   'must be a valid serializing perl module for use with MLDBM '.
   'such as Data::Dumper (default), or Storable',

   StatINC => "You need this module for StatINC, please download it from CPAN",
   
   'Cache' => "You need this module for xml output caching",

   UndefRoutine => '',
   
   XSLT => 'Cannot load XML::XSLT.  Try installing the module.',

  );


sub handler {
    my($package, $r) = @_;
    my $status = 200;
    
    # allows it to be called as an object method
    ref $package and $r = $package;

    # rarely happens, but just in case
    unless($r && $r->can('filename')) {
	# this could happen with a bad filtering sequence
	warn(<<ERROR);
no valid request object ($r) passed to ASP handler; if you are getting
this error message, you likely have a broken DSO version of mod_perl
which often occurs when using RedHat RPMs.  The fix here is to compile
statically the apache + mod_perl build.  Please check FAQ or mod_perl archives
for more information.
ERROR
  ;
       
	return 500;
    }

    # run time tracking
    my $start_time;
    if($r->dir_config('TimeHiRes')) {
	# request time tracking
	eval "use Time::HiRes";
	unless($@) {
	    $start_time = &Time::HiRes::time();	    
	}
    }

    # better error checking ?
    my $filename = $r->filename();
    return(404) if (! -e $filename or -d $filename);

    # alias $0 to filename, bind to glob for bug workaround
    local *0 = \$filename;

    # ASP object creation, a lot goes on in there!    
    my $self = new($r);
    $start_time and $self->{start_time} = $start_time;
    $self->Debug("start time ".($start_time || ''));
    
    $self->{stat_inc} && &StatINC($self);

    # there could be runtime errors in StatINC
    if(! $self->{errs} &IsChanged($self)) {
	my $script = &Parse($self);
	! $self->{errs} && &Compile($self, $script);
    }
    
    my $response = $self->{Response};
    if(! $self->{errs}) {
	#X: compensate for bug on Win32 that has this always set
	# screws with Apache::DBI 
	$Apache::ServerStarting and $Apache::ServerStarting = 0;
	my $global_asa = $self->{GlobalASA};
	$global_asa->{'exists'} && $global_asa->ScriptOnStart();
	unless($response->{Ended}) {
	    # execute only if an event handler hasn't already ended 
	    # things... this allows fine grain control of a response
	    # and executing scripts
	    &Execute($self);
	  APACHE_ASP_EXECUTE_END:
	}
	$global_asa->{'exists'} && $global_asa->ScriptOnEnd();
	! $self->{errs} && $response->EndSoft();
    }
    
    # moved print of object to the end, so we'll pick up all the 
    # runtime config directives set while the code is running
    $self->{dbg} && $self->Debug('ASP Done Processing', { 'asp' => $self });

    # error processing
    if($self->{errs}) {
	if($self->{dbg} >= 2) {
	    $self->PrettyError();
	} else {
	    if($self->{Response}{header_done}) {
		$self->{r}->print("<!-- Error -->");
	    }
	    
	    # debug of 2+ and mail_errors_to are mutually exclusive,
	    # since debugging 2+ is for development, and you don't need to 
	    # be emailed the error, if its right in your browser
	    $self->{mail_alert_to}  = $r->dir_config('MailAlertTo') || 0;
	    $self->{mail_errors_to} = $r->dir_config('MailErrorsTo') || 0;
	    $self->{mail_errors_to} && $self->MailErrors();
	    $self->{mail_alert_to} && $self->MailAlert();

	    $status = 500;
	}
    }

    # XX return code of 302 hangs server on WinNT
    # STATUS hook back to Apache
    if($status != 500 and defined $response->{Status} and $response->{Status} != 302) {
	# if still default then set to what has been set by the 
	# developer
	$status = $response->{Status};
    }

    # X: we DESTROY in register_cleanup, but if we are filtering, and we 
    # handle a virtual request to an asp app, we need to free up the 
    # the locked resources now, or the session requests will collide
    # a performance hack would be to share an asp object created between
    # virtual requests, but don't worry about it for now since using SSI
    # is not really performance oriented anyway.
    # 
    # If we are not filtering, we let RegisterCleanup get it, since
    # there will be a perceived performance increase on the client side
    # since the connection is terminated before the garabage collection is run.
    # 
    # Also need to destroy if we return a 500, as we could be serving an
    # error doc next, before the cleanup phase

    if($self->{filter} || ($status == 500)) {
	$self->DESTROY();
    }

    $status;
}

sub Warn {
    shift if(ref($_[0]) or $_[0] eq 'Apache::ASP');
    print STDERR "[ASP WARN] ", @_;
}

sub Loader {
    shift if(ref $_[0] or $_[0] eq 'Apache::ASP');

    local $SIG{__WARN__} = \&Warn;
    my($file, $match, %args) = @_;
    unless(-e $file) {
	warn("$file does not exist for loading");
	return;
    }
    $match ||= '.*'; # compile all by default

    # recurse down directories and compile the scripts
    if(-d $file) {
	$file =~ s|/$||;
	opendir(DIR, $file) || die("can't open $file for reading: $!");
	my @files = readdir(DIR);
	unless(@files) {
	    Apache::ASP::Loader->log_error("[asp] $$ [WARN] can't read files in $file");
	    return;
	}

	my $top;
	if(! defined $LOADED) {
	    $top = 1;
	}
	defined $LOADED or (local $LOADED = 0);
	defined $COUNT or (local $COUNT = 0);
	
	for(@files) {
	    chomp;
	    next if /^\.\.?$/;
	    &Loader("$file/$_", $match, %args);
	}
	if($top) {
	    Apache::ASP::Loader->log_error("[asp] $$ (re)compiled $LOADED scripts of $COUNT loaded");
	}
	return;
    } 

    # now the real work
    unless($file =~ /$match/) {
	if($args{Debug} < 0) {
	    Apache::ASP::Loader->log_error("skipping compile of $file no match $match");
	}
	return;
    }

    unless($file =~ /$match/) {
       if($args{Debug} < 0) {
           warn("skipping compile of $file no match $match");
       }
       return;
    }


    my $r = Apache::ASP::Loader::new($file);
    $r->dir_config('NoState', 1);
    $r->dir_config('Debug', $args{Debug});
    $r->dir_config('DynamicIncludes', $args{DynamicIncludes});
    $r->dir_config('IncludesDir', $args{IncludesDir});
    $r->dir_config('Global', $args{Global});
    $r->dir_config('GlobalPackage', $args{GlobalPackage});
    $r->dir_config('StatINC', $args{StatINC});
    $r->dir_config('StatINCMatch', $args{StatINCMatch});
    $r->dir_config('UseStrict', $args{UseStrict});
    
    eval {
	$COUNT++;
	my $asp = Apache::ASP::new($r);    

	my $compiled_includes = $Compiled{$asp->{subid}}->{compiled_includes};
	for(keys %$compiled_includes) {
	    $asp->CompileInclude($_);
	}
	if(! $asp->IsChanged()) {
	    $asp->DESTROY;
	    return;
	}

	my $script = $asp->Parse();
	$asp->Compile($script);
	if($asp->{errs}) {
	    warn("$asp->{errs} errors compiling $file while loading");
	    $asp->DESTROY;
	    return 0;
	} else {
	    $asp->DESTROY;
	    $LOADED++;
	    if($args{Execute}) {
		local *Apache::ASP::Response::Flush = sub {};
		$asp->Execute;
	    }
	}
    };
    $@ && warn($@);

    return 1;
}

sub new {
    my $r = shift;

    local $SIG{__DIE__} = \&Carp::confess;
    # like cgi, operate in the scripts directory
    my $filename = $r->filename();
    $filename =~ m|^(.*?[/\\]?)([^/\\]+)$|;
    my $dirname = $1 || '.';
    my $basename = $2;
    chdir($dirname) || die("can't chdir to $dirname: $!");

    # global is the default for the state dir and also 
    # a default lib path for perl, as well as where global.asa
    # can be found
    my $global = $r->dir_config('Global') || '.';
    $global = &AbsPath($global, $dirname);

    # asp object is handy for passing state around
    my $self = bless 
      { 
# moved to state config
#       app_state => (defined $r->dir_config('AllowApplicationState') ? 
#				   $r->dir_config('AllowApplicationState') : 1),
       
       'basename'     => $basename,

       # buffer output on by default
       # moved to Response
#       buffering_on   => (defined $r->dir_config('BufferingOn')) ? $r->dir_config('BufferingOn') : 1, 
       
       # if this is set we are parsing ourself through cgi
# moved to parsing
#       cgi_do_self        => $r->dir_config('CgiDoSelf') || 0, # parse self

# moved to response
#       cgi_headers        => $r->dir_config('CgiHeaders') || 0, 
#       clean          => $r->dir_config('Clean') || 0,

# moved to session init
       # this is the server path that the client responds to 
#       cookie_path    => $r->dir_config('CookiePath') || '/',
       
# moved to error
       # set for when we are executing from command line
#       command_line   => $r->dir_config('CommandLine'),
       
       # these are set by the Compile routine
#       compile_error  => undef, 
       compile_includes => $r->dir_config('DynamicIncludes'),
       
       'dbg'            => $r->dir_config('Debug') || 0,  # debug level
# not needed to store
#       'dirname'      => $dirname,
# will be defined when an error is created
#       errors_output  => [],

# null logic fine for errs
#       errs           => 0,
#       filehandle     => undef,
       filename       => $filename,

# moved to filter init
#       filter         => 0,

#       id             => undef, # parsed version of filename
       
       # where all the state and config files lie
       global         => $global,
       global_package => $r->dir_config('GlobalPackage'),
       
## moved to session config
       # refresh group by some increment smaller than session timeout
       # to withstand DoS, bruteforce guessing attacks
       # defaults to checking the group once every 2 minutes
#       group_refresh  => int($session_timeout / $state_manager),
       
       # name spaces which will have ASP objects initialized into
#       init_packages => undef,

       # additional path searched for includes when compiling scripts
#       includes_dir => $r->dir_config('IncludesDir'),
       includes_dir => [ '.', $global, split(/;/, $r->dir_config('IncludesDir') || '') ],


# move to error
#       mail_alert_to     => $r->dir_config('MailAlertTo'),
#       mail_errors_to    => $r->dir_config('MailErrorsTo'),
# moved to mailalert
#       mail_alert_period => $r->dir_config('MailAlertPeriod') || 20,
# moved to sendmail
#       mail_host         => $r->dir_config('MailHost'),
       
       # assume we already chdir'd to where the file is
#       mtime          => ((stat($basename))[9]),  # better than -M
       
       no_cache       => $r->dir_config('NoCache'),

# move to state config
#       no_session     => ((defined $r->dir_config('AllowSessionState')) ? (! $r->dir_config('AllowSessionState')) : 0),
       
       # set this if you don't want an Application or Session object
       # available to your scripts
       no_state       => $r->dir_config('NoState'),
# took out until someone might use it
#       order_collections => $r->dir_config('OrderCollections'),
#       'package'      => undef,
# moved to session config
#       paranoid_session => $r->dir_config('ParanoidSession') || 0,
       
       # moved to parse_config
	# default 1, should we parse out pod style commenting ?
#	pod_comments   => defined($r->dir_config('PodComments')) ? $r->dir_config('PodComments') : 1, 

	r              => $r, # apache request object 
# moved to session config
#	remote_ip      => $r->connection()->remote_ip(),
	
#	script_timeout => $r->dir_config('ScriptTimeout') || 90,
# moved session to session config
#	secure_session => $r->dir_config('SecureSession'),
#       session_count   => $r->dir_config('SessionCount'),
#       session_id      => undef, # set only when we know session id
#	session_timeout => undef,
#	session_serialize => $r->dir_config('SessionSerialize'),
#       session_url => $r->dir_config('SessionQuery'),
	
# move to redirect
#	soft_redirect  => $r->dir_config('SoftRedirect'),
       stat_scripts     => defined $r->dir_config('StatScripts') ? $r->dir_config('StatScripts') : 1,
       stat_inc       => $r->dir_config('StatINC'),    
       stat_inc_match => $r->dir_config('StatINCMatch'),
	
# moved state to state config
#        state_cache => $r->dir_config('StateCache'),
#	state_db       => $r->dir_config('StateDB') || 'SDBM_File',
#	state_dir      => $state_dir,
#	state_manager  => $state_manager,

# moved ua to session config
#       'ua' => $ENV{HTTP_USER_AGENT} || "UNKNOWN UA",
       unique_packages => $r->dir_config('UniquePackages'),
       use_strict      => $r->dir_config('UseStrict'),

# moved to parse_config
#       xml_subs_match  => $r->dir_config('XMLSubsMatch'),
       xslt => $r->dir_config('XSLT'),

	# special objects for ASP app
# set only when necessary
#	Application    => undef,
#	GlobalASA      => undef,
#	Internal       => undef,
#	Request        => undef,
#	Response       => undef,
#	Session        => undef,
#	Server         => undef,
      };
    
    # Only if debug is negative do we kick out all the internal stuff
    if($self->{dbg}) {
	if($self->{dbg} < 0) {
	    *Debug = *Out;
	    $self->{dbg} = -1 * $self->{dbg};
	} else {
	    *Debug = *Null;
	}
	$self->Debug('RUN ASP (v'. $VERSION .") for $self->{filename}");

	# capture use strict errors if debug is 2
#	if($self->{dbg}) {
#	    $self->{sig_warn} = $SIG{__WARN__};
#	    $SIG{__WARN__} = sub { $self->Out(@_) };
#	}
    } else {
	*Debug = *Null;
    }
    
    $self->{stat_inc_match} and $self->{stat_inc} = 1;

    # Ken said no need for seed ;)
#    unless($Apache::ASP::RandSeed) {
#	my $seed = $$.time;
#	$self->Debug("seed srand with $seed");
#	srand($seed);
#	$Apache::ASP::RandSeed = 1;
#    }

    if($self->{no_cache}) {
	# this way subsequent recompiles overwrite each other
	$self->{id} = 'NoCache';
    } else {
	# was call to FileId, removed decomp for speed
	my $id = $self->{filename}.'x'.($self->{compile_includes} ? 'DYN' : 'INL');
	$id =~ s/\W/_/g;
	$self->{id} = $id;
    }

    # filtering support
    my $filter_config = $r->dir_config('Filter') || $Apache::ASP::Filter;
    if($filter_config && ($filter_config !~ /off/io)) {
        if($self->LoadModules('Filter', 'Apache::Filter') 
	   && $r->can('filter_input') && $r->can('get_handlers')) 
	  {
	      $self->{filter} = 1;
	      #X: do something with the return code, can't now because
	      # apache constants aren't working on my win32
	      my($fh, $rc) = $r->filter_input();
	      $self->{filehandle} = $fh;
	  } else {
	      if(! $r->can('get_handlers')) {
		  $self->Error("You need at least mod_perl 1.16 to use SSI filtering");
	      } else {
		  $self->Error("Apache::Filter was not loaded correctly for using SSI filtering.  ".
			       "If you don't want to use filtering, make sure you turn the Filter ".
			       "config option off whereever it's being used");
	      }
	  }
    }
    
    # gzip content encoding option by ime@iae.nl 28/4/2000
    my $compressgzip_config = $r->dir_config('CompressGzip') || $Apache::ASP::CompressGzip;
    if($compressgzip_config && $compressgzip_config !~ /off/io) {	
	if($self->LoadModule('Gzip','Compress::Zlib')) {
	    $self->{compressgzip} = 1;
	}
    }    
     
    # must have global directory into which we put the global.asa
    # and possibly state files, optimize out the case of . or ..
    if($self->{global} !~ /^(\.|\.\.)$/) {
	-d $self->{global} or 
	  $self->Error("global path, $self->{global}, is not a directory");
    }

    # register cleanup before the state files get set in InitObjects
    # this way DESTROY gets called every time this script is done
    # we must cache $self for lookups later
    $Register = $self;
    $r->register_cleanup(\&Apache::ASP::RegisterCleanup);

    #### WAS INIT OBJECTS, REMOVED DECOMP FOR SPEED

    # GLOBALASA, RESPONSE, REQUEST, SERVER
    # always create these
    # global_asa assigns itself to parent object automatically
    my $global_asa = &Apache::ASP::GlobalASA::new($self);
    $self->{subid} = $global_asa->{'package'}.'::'.$self->{id};
    $self->{Response}  = &Apache::ASP::Response::new($self);
    $self->{Request}   = &Apache::ASP::Request::new($self);
    # Server::new() is just one line, so execute directly
    $self->{Server}    = bless {asp => $self}, 'Apache::ASP::Server';
    #&Apache::ASP::Server::new($self);

    # After GlobalASA Init, init the package that this script will execute in
    # must be here, and not end of new before things like Application_OnStart
    # get run
    if($self->{unique_packages}) {
	$self->{id} .= "::handler" unless($self->{no_cache});
	my $package = $global_asa->{'package'}.'::'.$self->{id};
	$package =~ s/::[^:]+$//;
	$self->{'package'} = $package;
	$self->{init_packages} = ['main', $global_asa->{'package'}, $self->{'package'}];	
    } else {
	$self->{'package'} = $global_asa->{'package'};
	$self->{init_packages} = ['main', $global_asa->{'package'}];	
    }

    # WHY? cut out now before we get to the big objects
#    return if $self->{errs};

    # if no state has been config'd, then set up none of the 
    # state objects: Application, Internal, Session
    return($self) if $self->{no_state};
#    my $r = $self->{'r'};

    ## STATE INITS
    # what percent of the session_timeout's time do we garbage collect
    # state files and run programs like Session_OnEnd and Application_OnEnd
    $self->{state_manager} = $r->dir_config('StateManager') 
      || $Apache::ASP::StateManager;    

    # state is the path where state files are stored, like $Session,
    # $Application, etc.
    $self->{state_cache} = $r->dir_config('StateCache');
    $self->{state_dir}   = $r->dir_config('StateDir') || $self->{global}.'/.state';
    $self->{state_dir}   =~ /^(.*)$/; # untaint
    $self->{state_dir}   = $1; # untaint
    $self->{no_session}  = (defined $r->dir_config('AllowSessionState')) ? (! $r->dir_config('AllowSessionState')) : 0;
    
    if($self->{state_db}    = $r->dir_config('StateDB')) {
	# StateDB - Check StateDB module support 
	$Apache::ASP::State::DB{$self->{state_db}} ||
	  $self->Error("$self->{state_db} is not supported for StateDB, try: " . 
		       join(", ", keys %Apache::ASP::State::DB));
	$self->{state_db} =~ /^(.*)$/; # untaint
	$self->{state_db} = $1; # untaint
	# load the state database module && serializer
	$self->LoadModule('StateDB', $self->{state_db});
    }
    if($self->{state_serializer} = $r->dir_config('StateSerializer')) {
	$self->{state_serializer} =~ /^(.*)$/; # untaint
	$self->{state_serializer} = $1; # untaint
	$self->LoadModule('StateSerializer', $self->{state_serializer});
    }

    # INTERNAL tie to the application internal info
    my %Internal;
    tie(%Internal, 'Apache::ASP::State', $self, 'internal', 'server', O_RDWR|O_CREAT)
      || $self->Error("can't tie to internal state");
    my $internal = $self->{Internal} = bless \%Internal, 'Apache::ASP::State';

    # APPLICATION create application object
    $self->{app_state} = (defined $r->dir_config('AllowApplicationState') ? 
			   $r->dir_config('AllowApplicationState') : 1);
    if($self->{app_state}) {	
	($self->{Application} = &Apache::ASP::Application::new($self)) 
	  || $self->Error("can't get application state");
	if($self->{dbg}) {
	    $self->{Application}->Lock();
	    $self->Debug('created $Application', $self->{Application});
	    $self->{Application}->UnLock();	
	}
    } else {
	$self->{dbg} && $self->Debug("no application allowed config");
    }

    # SESSION if we are tracking state, set up the appropriate objects
    if(! $self->{no_session}) {
	## SESSION INITS
	$self->{cookie_path}       = $r->dir_config('CookiePath') || '/';
	$self->{paranoid_session}  = $r->dir_config('ParanoidSession') || 0;
	$self->{remote_ip}         = $r->connection()->remote_ip();
	$self->{session_count}     = $r->dir_config('SessionCount');
	
	# cookieless session support, cascading values
	$self->{session_url_parse_match} = $r->dir_config('SessionQueryParseMatch');
	$self->{session_url_parse} = $self->{session_url_parse_match} || $r->dir_config('SessionQueryParse');
	$self->{session_url_match} = $self->{session_url_parse_match} || $r->dir_config('SessionQueryMatch');
	$self->{session_url} = $self->{session_url_parse} || $self->{session_url_match} || $r->dir_config('SessionQuery');
	
	$self->{session_serialize} = $r->dir_config('SessionSerialize');
	$self->{secure_session}    = $r->dir_config('SecureSession');
	# session timeout in seconds since that is what we work with internally
	$self->{session_timeout}   = $r->dir_config('SessionTimeout') ? 
	  $r->dir_config('SessionTimeout') * 60 : $Apache::ASP::SessionTimeout;
	$self->{'ua'}              = $ENV{HTTP_USER_AGENT} || 'UNKNOWN UA';
	# refresh group by some increment smaller than session timeout
	# to withstand DoS, bruteforce guessing attacks
	# defaults to checking the group once every 2 minutes
	$self->{group_refresh}     = int($self->{session_timeout} / $self->{state_manager});
	
	# Session state is dependent on internal state
	my $session = $self->{Session} = &Apache::ASP::Session::new($self)
	  || $self->Die("can't create session");
	my $last_session_timeout;
	if($session->Started()) {
	    # we only want one process purging at a time
	    if($self->{app_state}) {
		$internal->LOCK();
		if(($last_session_timeout = $internal->{LastSessionTimeout} || 0) < time()) {
		    $internal->{'LastSessionTimeout'} = $self->{session_timeout} + time;
		    $internal->UNLOCK();
		    if($self->CleanupGroups('PURGE')) {
			$last_session_timeout && $global_asa->ApplicationOnEnd();
			$global_asa->ApplicationOnStart();
		    }
		} 
		$internal->UNLOCK();
	    }
	    $global_asa->SessionOnStart();
	}

	if($self->{app_state}) {
	    # The last session timeout should only be updated every group_refresh period
	    # another optimization, rand() so not all at once either
	    $internal->LOCK();
	    $last_session_timeout ||= $internal->{'LastSessionTimeout'};
	    if($last_session_timeout < $self->{session_timeout} + time + 
	       (rand() * $self->{group_refresh} / 2)) 
	      {
		  $self->{dbg} && $self->Debug("updating LastSessionTimeout from $last_session_timeout");
		  $internal->{'LastSessionTimeout'} = 
		    $self->{session_timeout} + time() + $self->{group_refresh};
	      }
	    $internal->UNLOCK();
	}
    } else {
	$self->{dbg} && $self->Debug("no sessions allowed config");
    }
    
    $self;
}

# registered in new() so that is called every end of connection
sub RegisterCleanup {
    $Register && DESTROY($Register);
}
    
# called upon every end of connection by RegisterCleanup
sub DESTROY {
    my $self = shift;

    return unless (defined($Register) and $self eq $Register);
    $Register = undef;
    $self->{dbg} && $self->Debug("destroying", $self);
    
    # do before undef'ing the object references in main
    if(@Apache::ASP::Cleanup) {
	for(@Apache::ASP::Cleanup) {
	    $self->Debug("executing cleanup $_");
	    eval { &$_ };
	    $@ && $self->Error("executing cleanup $_ error: $@");
	}
	@Apache::ASP::Cleanup = ();
    }

    local $^W = 0; # suppress untie while x inner references warnings
    select(STDOUT); 
    untie *STDIN if tied *STDIN;

#    if($self->{dbg}) {
#	$SIG{__WARN__} = $self->{sig_warn} || \&warn;
#    }

    # undef objects in main set up in execute, do after cleanup,
    # so cleanup routine can still access objects
#    for $object (@Apache::ASP::Objects) {
#	for $package (@{$self->{init_packages}}) {
#	    my $init_var = $package.'::'.$object;
#	    undef $$init_var;
#	}
#    }

    # we try to clean up our own group each time, since this way the 
    # cleanup load should be spread out amongst processes.  If the
    # server is really busy, CleanupGroups() won't get to do anything,
    # but if the server is slow, CleanupGroups is essential so that 
    # some Sessions actually get ended, and Session_OnEnd gets called
    if($self->{Session}) {
	$self->CleanupGroups();
#	$self->CleanupGroup();  
    }

    # free file handles here.  mod_perl tends to be pretty clingy
    # to memory
    for('Application', 'Internal', 'Session') {
	# all this stuff in here is very necessary for total cleanup
	# the DESTROY is the most important, as we need to explicitly free
	# state objects, just in case anyone else is keeping references to them
	# But the destroy won't work without first untieing, go figure
	next unless defined $self->{$_};
	my $tied = tied %{$self->{$_}};
	next unless $tied;
	untie %{$self->{$_}};
	$tied->DESTROY(); # call explicit DESTROY
    }

    #    $self->{'dbg'} && $self->Debug("END ASP DESTROY");
    $self->{Request} && $self->{Request}->DESTROY();
    %$self = ();

    1;
}

sub RefreshSessionId {
    my($self, $id, $reset) = @_;
    $id || $self->Error("no id for refreshing");
    my $internal = $self->{Internal};

    my $idata = $internal->{$id};    
    my $refresh_timeout = $reset ? 
      $self->{session_timeout} : $idata->{refresh_timeout} || $self->{session_timeout};
    $idata->{'timeout'} = time() + $refresh_timeout;
    $internal->{$id} = $idata;	
    $self->{dbg} && $self->Debug("refreshing $id with timeout $idata->{timeout}");

    1;
}

sub FileId {
    my $file = $_[1];
    $file =~ s/\W/_/gso;
    $file;
}

sub IsChanged {
    my $self = shift;

## WHY ??? With proper reloading, the script and lib should
## be independent.  And this is not consistent, all other scripts
## should also be reloaded after StatINC if one does.

    # do the StatINC if we are config'd for it
    # we return true if stat inc tells us that some
    # libraries had been changed, since a script is
    # new if the library is new under it.
#    if($self->{stat_inc}) { 
#	return(1) if $self->StatINC(); 
#    }

    # support for includes, changes to included files
    # cause script to recompile
    if($self->{stat_scripts} and 
       my $includes = $Apache::ASP::Includes{$self->{id}}) 
      { 
	  for my $k (keys %$includes) {
	      my $v = $includes->{$k};
	      if((stat($k))[9] > $v) {
		  return 1;
	      }
	  }
      }

    # always recompile if we are not supposed to cache
    if($self->{no_cache}) {
	return 1;
    }

    my $last_update = $Apache::ASP::Compiled{$self->{subid}}->{mtime} || 0;
    if(! $self->{stat_scripts} && $last_update) {
	$self->{dbg} && $self->Debug("no stat: script already compiled");
	return 0;
    }

    if($self->{filter}) {
	$self->{r}->changed_since($last_update);
    } else {
	$self->{mtime} = (stat($self->{basename}))[9];
	# we only get here if we have a chance of caching and all
	# our dependent components have not changed
	($self->{mtime} > $last_update) ? 1 : 0;
    }
}        

# defaults to parsing the script's file, or data from a file handle 
# in the case of filtering, but we can also pass in text to parse,
# which is useful for doing includes separately for compiling
sub Parse {
    my($self, $file) = @_;
    my $data;
    my $id = $self->{'id'};

    # get script data, from varied data sources
    my $filehandle;
    if($file) {
	# file can be a filename, scalar ref, or scalar
	if(length($file) < 1024 and -e $file) {
	    # filename has length < 1024, should be fine across OS's
	    $self->{dbg} && $self->Debug("parsing $file");
	    $data = $self->ReadFile($file);	
	} elsif(ref $file and $file =~ /SCALAR/) {
	    $data = $$file;
	} else {
	    $data = $file;
	}
    } else {
	if($filehandle = $self->{filehandle}) {
	    local $/ = undef;
	    $data = <$filehandle>;
	} else {
	    $self->{dbg} && $self->Debug("parsing $self->{'basename'}");
	    $file = $self->{'basename'};
	    $data = $self->ReadFile($self->{'basename'});

	    # reset compiled includes for scripts
	    $Compiled{$self->{subid}}->{compiled_includes} = {};
	}
    }
    my $script_compiled_includes = $Compiled{$self->{subid}}->{compiled_includes};

    if($self->{r}->dir_config('CgiDoSelf')) {
	$data =~ s/^(.*?)__END__//gso;
    }

    # moved parsing config here since not needed for normal
    # eval execution of scripts after compilation
    unless($self->{parse_config}) {
	my $r = $self->{r};
	$self->{parse_config} = 1;
	$self->{pod_comments} = defined($r->dir_config('PodComments')) ? 
	  $r->dir_config('PodComments') : 1;
	$self->{xml_subs_match} = $r->dir_config('XMLSubsMatch');
    }    

    # do both before and after, so =pods can span includes with =pods
    if($self->{pod_comments}) {
	&PodComments($self, \$data);
    }

    # if compiling includes, then do now before includes conversion
    # each include will also have its Script_OnParse run on it.
    if($self->{compile_includes} && $self->{GlobalASA}{'exists'}) {	
	$self->{Server}{ScriptRef} = \$data;
	$self->{GlobalASA}->Execute('Script_OnParse');		
    }

    # do includes as early as possible !! so included text gets done too
    # this section is for file includes, we do this here instead of ssi
    # so it can be parsed and compiled with the script
    local %includes; # trap recursive includes with this
    my $munge = $data;
    $data = '';
    while($munge =~ s/^(.*?)\<!--\#include\s+file\s*=\s*\"?([^\s\"]*?)\"?(\s+args\s*=\s*\"?.*?)?\"?\s*--\>//so) {
	$data .= $1; # append the head
	my $file = $2;

	# compiled include args handling
	my $has_args = $3;
	my $args = undef;
	if($has_args) {
	    $args = $has_args;
	    $args =~ s/^\s+args\s*\=\s*\"?//sgo;
	}
	

	# global directory, as well as includes dirs
	my $include = $self->SearchDirs($file);
	unless(defined $include) { 
	    $self->Error("include file with name $file does not exist");
	    return;
	}
	if($self->{dbg}) {
	    if($include ne $file) {
		$self->Debug("found $file at $include");
	    }
	}

	# trap the includes here, at 100 levels like perl debugger
	if(defined($args) || $self->{compile_includes}) {
	    # because the script is literally different whether there 
	    # are includes or not, whether we are compiling includes
	    # need to be part of the script identifier, so the global
	    # caching does not return a script with different preferences.
	    $self->{dbg} && $self->Debug("runtime exec of dynamic include $file args (".
					 ($args || '').')');
	    $data .= "<% \$Response->Include('$include', $args); %>";
	    
	    # compile include now, so Loading() works for dynamic includes too
	    unless($self->CompileInclude($include)) {
		$self->Error("compiling include $include failed when compiling script");
	    }		   
	    $script_compiled_includes->{$include}++;		
	} else {
	    $self->Debug("inlining include $include");
	    # DEFAULT, not compile includes, or inline includes,
	    # the included text is inlined directly into the script
	    if($includes{$include}++ > 100) {
		$self->Error("Recursive include detected for $include 100 levels deep! ".
			     "Your includes are including each other.  If you ".
			     "are getting this error with a legitimate use of includes ".
			     "please mail support about this error "
			    );
		return;
	    }
	    
	    # put the included text into what we are parsing, allows for
	    # includes having includes
	    $id || $self->Error("need id for includes");
	    $Apache::ASP::Includes{$id}->{$include} = (stat($include))[9];
	    my $text = $self->ReadFile($include);
	    $text =~ s/^\#\![^\n]+(\n\n?)/$1/s; #X cgi compat ?
	      $munge = $text . $munge; 
	}
    }
    $data .= $munge; # append what's left   

    # call Script_OnParse after instead if we inline includes at all
    # so we have the full script for people
    if(! $self->{compile_includes}) {	
	# do pod comments again if we have any included files
	if(%includes && $self->{pod_comments}) {
	    &PodComments($self, \$data);
	}
	if($self->{GlobalASA}{'exists'}) {	
	    $self->{Server}{ScriptRef} = \$data;
	    $self->{GlobalASA}->Execute('Script_OnParse');		
	}
    }

#    $self->Debug("parsing includes done $self->{'basename'}");

    # strip carriage returns; do this as early as possible, but after includes
    # since we want to rip out the carriage returns from them too
    my $CRLF = "\015\012";
    $data =~ s/$CRLF/\n/sgo;
    $data =~ s/^\#\![^\n]+(\n\n?)/$1/s; #X cgi compat ?

    # JUST ONCE
    # there should only be one of these, <%@ LANGUAGE="PerlScript" %>, rip it out
    # we keep white space and substitue text in so the perlscript sync's up with lines
    # only take out the first one 
    $data =~ s/^(^\s*)\<\%(\s*)\@([^\n]*?)\%\>/$1\<\%$2 ; \%\>/so; 
    $data =~ s/\s+$//so; # strip trailing white space

    my $script = &ParseHelper($self, \$data);

    my $strict = $self->{use_strict} ? "use strict" : "no strict";
    $$script = join(";;", 
		   $strict,
		   "use vars qw(\$".join(" \$",@Apache::ASP::Objects).')',
		   $$script
		   );

    $script;
}

sub ParseHelper {
    my($self, $data) = @_;
    my($script, $text, $perl);

    if($self->{xml_subs_match}) {
	unless($self->{asp}{xslt}) {
	    $$data =~ s|\s*\<\?xml\s+version\s*\=[^\>]+\?\>||is;
	}
	$self->{xml_subs_match} =~ s/[\(\)]//sg;
	$$data =~ s|\<\s*($self->{xml_subs_match})([^\>]*)/\>
	  | {
	     my($func, $args) = ($1, $2);
	     $func =~ s/\:/\:\:/g;
	     $args =~ s/([^\s]+\s*)\=(\s*)([\s\'\"]?)([^\3]*)(\3)/$1\=\>$2$3$4$5/sg;
	     "<% $func({ $args }, ''); %>"
	    } |sgex;	    
	$$data =~ s|
	  \<\s*($self->{xml_subs_match})([^\>]*)\>(.*?)\<\/\1\s*\>
	    | {
	       my($func, $args, $text) = ($1, $2, $3, $4);
	       
	       $func =~ s/\:/\:\:/g;
	       $args =~ s/( [^\s]+\s*)\=/,$1\=\>/sg;
	       $args =~ s/^,//s;
	       
	       if($text =~ /\<\%.*\%\>/) {
		   # parse again, and control output buffer for this level
		   my $sub_script = &ParseHelper($self, \$text);
		   $text = (
			    ' &{sub{ my $out = ""; '.
			    'local $Response->{out} =  local $Response->{BinaryRef} = \$out; '.
			    'local *Apache::ASP::Response::Flush = *Apache::ASP::Response::Null; '.
			    $$sub_script .
			    ' ; ${$Response->{out}}; }} '
			   );
	       } else {
		   # raw text
		   $text =~ s/\\/\\\\/gso;
		   $text =~ s/\'/\\\'/gso;	
		   $text = "'$text'";
	       }
	       
	       "<% $func({ $args }, $text); %>"
	      } |sgex;
    }

    my(@out, $perl_block, $last_perl_block);
    $$data .= "<%;;;%>"; # always end with some perl code for parsing.
    while($$data =~ s/^(.*?)\<\%(.*?)\%\>//so) {
	($text, $perl) = ($1,$2);
	$perl_block = ($perl =~ /^\s*\=(.*)$/so) ? 0 : 1;
	my $perl_scalar = $1;

	# with some extra text parsing, we remove asp formatting from
	# influencing the generated html formatting, in particular
	# dealing with perl blocks and new lines
	if($text) {
	    # don't touch the white space, to preserve line numbers
	    $text =~ s/\\/\\\\/gso;
	    $text =~ s/\'/\\\'/gso;

	    if($last_perl_block) {
		$last_perl_block = 0;
	    }

	    push(@out, "\'".$text."\'")
	}

	if($perl) {
	    if(! $perl_block) {
		# we have a scalar assignment here
		push(@out, '('.$perl_scalar.')');
	    } else {
		$last_perl_block = 1;
		if(@out) {
		    # we pass by reference here with the idea that we are not
		    # copying the HTML twice this way.  This might be large
		    # saving on a typical site with rich HTML headers & footers
		    $script .= '$main::Response->WriteRef(\('.join('.', @out).'));'; 
		    @out = ();
		}			 

		# allow old <% #comment %> style to still work, but we
		# need to insert a newline at the end of the comment for 
		# it to still exist, with the lines now being sync'd up
		# if these old comments still exist, they perl script
		# will be off by one line from the asp script
		if($perl =~ /\#[^\n]*?$/so) {
		    $perl .= "\n";
		}

		# skip if the perl code is just a placeholder		
		unless($perl eq ';;;') {
		    $script .= $perl . '; ';
		}
	    }
	}
    }

    \$script;
}

sub PodComments {
    my $data = $_[1];
    
    # we do a little extra work to sync pod comment lines up, we do this
    # by wiping out the pod comments, and replacing them with the equivalent
    # number of newlines
    $$data =~ s,(^|\n)(\=pod\n.*?\n\=cut\n),
      {
       my $pod = $1.$2;
       $pod =~ s/[^\n]+//sg;
       $pod;
      }
    ,sgex;
    
    $data;
}

sub SearchDirs {
    my($self, $file) = @_;
 
    if(defined $file) {
	# test & return if absolute if absolute
	if($file =~ m,^/|^[a-z]\:,i) {
	    return (-e $file) ? $file : undef;
	}
	
	for my $dir (@{$self->{includes_dir}}) {
	    my $path = "$dir/$file";
	    return $path if -e $path;
        }
    }
    
    undef;
}

sub CompileInclude {
    my($self, $include) = @_;

    my $file = $self->SearchDirs($include);
    die("no file $include") unless defined $file;
    $include = $file;

    my $id = $self->FileId($self->AbsPath($include, $self->{global}));    
    my $subid = $self->{GlobalASA}{'package'}."::$id".'_x_INC';

    my $compiled = $Apache::ASP::CompiledIncludes{$subid};
    if($compiled && ! $self->{stat_scripts}) {
	$self->Debug("no stat: found cached code for include $id");
	return $compiled;
    }
    
    # return cached code if include hasn't been modified recently
    my $mtime = (stat($include))[9];
    if($compiled && ($compiled->{mtime} >= $mtime)) {
#	$self->Debug("found cached code for include $id");
	return $compiled;
    } 

    my $perl = $self->Parse($include);
    $self->UndefRoutine($subid);
    $self->{dbg} && $self->Debug("compile include $include sub $id");

    # COMPILE STRICT ODDITIES: use strict won't throw an error, but will
    # destroy a compilation of a sub routine, returning an invalid reference
    # we create the sub with a way to do a dummy execution of it, no args, 
    # and then do a null execute, testing for eval error.
    # use strict seems to print to STDERR directly w/o throwing an error,
    # if it just triggered a die(), we wouldn't have a problem
    my $eval = join(" ",
		    "package $self->{GlobalASA}{'package'};",
		    "sub $id { $$perl }",
		    "1;"
		   );

    my $name = "$self->{GlobalASA}{'package'}::$id";    
    $eval =~ /^(.*)$/s; # untaint
      
    if($self->{use_strict}) { 
	local $SIG{__WARN__} = sub { die("maybe use strict error: ", @_) };
	eval $1;
    } else {
	eval $1;
    }

    my $create_err = $@;    
    if($@) {	
	$self->CompileError($perl, "error compiling include $file: $@");

	# we don't want to cache the compiled routine, so jump out here
	# this will make ASP keep trying to recompile it
	return;
    }

    $self->RegisterSubs($id, $eval);
    $Apache::ASP::CompiledIncludes{$subid} = 
      { 
       mtime => $mtime, 
       code => $name, 
       perl => $perl, 
       file => $include 
      };
}

sub UndefRoutine {
    my($self, $subid) = @_;

    if(defined(\&{$subid})) {
	my $code = \&{$subid};
	if($self->LoadModules('UndefRoutine', 'Apache::Symbol')) {
	    $self->Debug("active undefing sub $subid code $code");
	    &Apache::Symbol::undef($code);
	} else {
	    $self->Debug("undefing sub $subid code $code");
	    undef($code);
	}
    }
}

sub ReadFile {
    my($self, $file) = @_;

    local *READFILE;
    open(READFILE, $file) || $self->Error("can't open file $file for reading");
    local $/ = undef;
    my $data = <READFILE>;
    close READFILE;

    $data;
}

# if the $file is an absolute path, then just return the file
# if the $file is a relative path, concat it with the passed in directory
sub AbsPath {
    shift if ref($_[0]);
    my($file, $dir) = @_;

    # we test for first unix style and then win32 style path conventions
    if($file =~ m|^/| or $file =~ m|^.\:|) {
	$file;
    } else {
	# we only can absolute the path if the directory path is absolute
	if($dir =~ m|^/| or $dir =~ m|^.\:|) {
	    $file = $dir.'/'.$file;
	} else {
	    $file;
	}
    }
}       
    
sub Compile {
    my($self, $script, $subid) = @_;
    $subid ||= $self->{subid};

    unless($script) {
	my $null = '';
	$script = \$null;	
    }
    
    $self->UndefRoutine($subid);
    $self->{dbg} && $self->Debug("compiling into package $self->{'package'} subid $subid");    

    my $eval = 
      join(" ;; ", 
	   "package $self->{'package'};",
	   "sub $subid { ",
	   ' @_ = ();',
	   $$script,
	   '}',
	  );

    $eval =~ /^(.*)$/s; # untaint

    if($self->{use_strict}) { 
	local $SIG{__WARN__} = sub { die("maybe use strict error: ", @_) };
	eval $1;
    } else {
	eval $1;
    }
    

    if($@) {
	$self->CompileError($eval, $@);
	$self->UndefRoutine($subid);
    } 

    if(! $self->{compile_error}) {
	$Apache::ASP::Compiled{$subid}->{mtime}  = $self->{mtime};
	if($self->{'package'} eq $self->{GlobalASA}{'package'}) {
	    $self->RegisterSubs($self->{subid}, $eval);
	}
    }
    $Apache::ASP::Compiled{$subid}->{output} = $eval;	
    
    ! $self->{errs};
}

sub RegisterSubs {
    my($self, $id, $script) = @_;
    
    my $global_package = $self->{GlobalASA}{'package'};
    while($script =~ s/(^|\n)sub\s+([^\s\{]+)\s*\{//s) {
	my $sub = $2;
	if($sub =~ /\:\:/) {
	    # absolute sub, don't touch it
	} else {
	    # else defined in global package
	    $sub = $global_package.'::'.$sub;
	}
	$self->Debug("registering sub $sub at $id");
	if($ScriptSubs{$sub}) {
	    if($ScriptSubs{$sub} ne $id) {
		$self->Log("[WARN] redefinition of subroutine $sub at $id, ".
			   "originally defined at $ScriptSubs{$sub}");
		$ScriptSubs{$sub} = $id;
	    }
	} else {
	    $ScriptSubs{$sub} = $id;
	}
    }
}

sub Execute {
    my $self = shift;    
    my $id = shift || $self->{id};
    my $subid = $self->{GlobalASA}{'package'}.'::'.$id;
    $self->{dbg} && $self->Debug("executing $id");
    
    # init objects, skip if already done for this asp object,
    # which will speed execution of GlobalASA subs
    my($object, $import_package);
    for $object (@Apache::ASP::Objects) {
	next if (defined $self->{packages_init}{$object} and 
		 ($self->{packages_init}{$object} || '') eq ($self->{$object} || ''));
	$self->{packages_init}{$object} = $self->{$object} || '';
	for $import_package (@{$self->{init_packages}}) {
	    my $init_var = $import_package.'::'.$object;	    
	    $$init_var = $self->{$object};	    
	}
    }
    
    # set printing to Response object
    unless($self->{response_tied}) {
	$self->Debug("tieing response package for STDOUT");
	$self->{response_tied} = 1;
	tie *RESPONSE, 'Apache::ASP::Response', $self->{Response};
	select(RESPONSE);
    }
	
    # don't do RequestOnStart & OnEnd here as they end up calling Execute()
    # again, and we fall into a recursive black hole.
    # run the script now, then check for errors
    
#    $self->{r}->soft_timeout(1);
    eval { &$subid() };
    if($@ && $@ !~ /Apache\:\:exit/) { 
	$self->Error($@); 
    }
    
    # NOT NECESSARY, if filtering, we call destroy now
    # filtering makes us keep this here instead of DESTROY
    # also in DESTROY in case scripts gets killed by STOP
    #    select(STDOUT); 

    ! $@;
}

# Cleanup a state group, by default the group of the current session
# We do this currently in DESTROY, which happens after the current
# script has been executed, so that cleanup doesn't happen until
# after output to user
#
# We always exit unless there is a $Session defined, since we only 
# cleanup groups of sessions if sessions are allowed for this script
sub CleanupGroup {
    my($self, $group_id, $force) = @_;
    return unless $self->{Session};

    my $asp = $self; # bad hack for some moved around code
    $force ||= 0;

    # GET GROUP_ID
    my $state;
    unless($group_id) {
	$state = $self->{Session}{_STATE};
	$group_id = $state->GroupId();
    }

    # we must have a group id to work with
    $asp->Error("no group id") unless $group_id;
    my $group_key = "GroupId" . $group_id;

    # cleanup timed out sessions, from current group
    my $internal = $asp->{Internal};
    $internal->LOCK();
    my $group_check = $internal->{$group_key} || 0;
    unless($force || ($group_check < time())) {
	$internal->UNLOCK();
	return;
    }
    
    # set the next group_check
    $internal->{$group_key} = time() + $asp->{group_refresh};
    $internal->UNLOCK();
    $asp->{dbg} && $asp->Debug("group check $group_id");

    ## GET STATE for group
    $state ||= &Apache::ASP::State::new($asp, $group_id);

    my $id = $self->{Session}->SessionID();
    my $deleted = 0;
    my $ids = $state->GroupMembers();
    my $total = @{$ids};
    for(@{$ids}) {
	if($id eq $_) {
	    $asp->Debug("skipping delete self", {id => $id});
	    next;
	}

	# we lock the internal, so a session isn't being initialized
	# while we are garbage collecting it... we release it every
	# time so we don't starve session creation if this is a large
	# directory that we are garbage collecting
	$internal->LOCK();
	my $timeout = $internal->{$_}{timeout} || 0;
	
	unless($timeout) {
	    # we don't have the timeout always, since this session
	    # may just have been created, just in case this is 
	    # a corrupted session (does this happen still ??), we give it
	    # a timeout now, so we will be sure to clean it up 
	    # eventualy
	    my $idata = $internal->{$_};
	    $idata->{timeout} = time() + $asp->{session_timeout};
	    $internal->{$_} = $idata;
	    $asp->Debug("resetting timeout for $_ to $idata->{timeout}");
	    $internal->UNLOCK();
	    next;
	}	
	# only delete sessions that have timed out
	unless($timeout < time()) {
	    $asp->Debug("not timed out with $timeout");
	    $internal->UNLOCK();
	    next;
	}
	
	# UPDATE & UNLOCK, as soon as we update internal, we may free it
	# definately don't lock around SessionOnEnd, as it might take
	# a while to process	
	
	# set the timeout for this session forward so it won't
	# get garbage collected by another process
	$asp->Debug("resetting timeout for deletion lock on $_");
	$internal->{$_} = {
			   %{$internal->{$_}},
			   'timeout' => time() + $asp->{session_timeout}
			  };
	$internal->UNLOCK();
	
	# Run SessionOnEnd
	$asp->{GlobalASA}->SessionOnEnd($_);

	# set up state
	my($member_state) = Apache::ASP::State::new($asp, $_);	
	if(my $count = $member_state->Delete()) {
	    $asp->{dbg} && 
	      $asp->Debug("deleting session", {
					       session_id => $_, 
					       files_deleted => $count,
					      });
	    $deleted++;
	    delete $internal->{$_};
	} else {
	    $asp->Error("can't delete session id: $_");
	    next;
	}
    }
    
    # REMOVE DIRECTORY, LOCK 
    # if the directory is still empty, remove it, lock it 
    # down so no new sessions will be created in it while we 
    # are testing
    if($deleted == $total) {
	$asp->{Internal}->LOCK();
	my $ids = $state->GroupMembers();
	if(@{$ids} == 0) {
	    $state->DeleteGroupId();
	}
	$asp->{Internal}->UNLOCK();
    }

    $deleted;
}

sub CleanupMaster {
    my $self = shift;
    my $internal = $self->{Internal};
    
    $internal->LOCK;
    my $master = $internal->{CleanupMaster} || 
      {
       ServerID => '',
       PID => 0,
       Checked => 0,       
      };

    my $is_master = $master->{ServerID} eq $ServerID 
      and $master->{PID} eq $$ ? 1 : 0;
    my $stale_time = $is_master ? $self->{group_refresh} / 4 : $self->{group_refresh} / 2;
    $stale_time += $stale_time * rand() / 2 + $master->{Checked};
    
    if($stale_time < time()) {
	$internal->{CleanupMaster} =
	  {
	   ServerID => $ServerID,
	   PID => $$,
	   Checked => time()
	  };
	$internal->UNLOCK;
	$self->{dbg} && $self->Debug("$stale_time time is stale, is_master $is_master", $master);
	
	# we are only worried about multiprocess NFS here
	sleep(1) unless ($^O =~ /Win/); 

	my $master = $internal->{CleanupMaster};
	my $is_master = $master->{ServerID} eq $ServerID 
	  and $master->{PID} eq $$ ? 1 : 0;
	$self->{dbg} && $self->Debug("is master after update $$");
	$is_master;
    } elsif($is_master) {
	$master->{Checked} = time();
	$internal->{CleanupMaster} = $master;
	$internal->UNLOCK;
	$self->{dbg} && $self->Debug("$stale_time time is fresh, is_master $is_master", $master);
	1; # is master
    } else {
	$internal->UNLOCK;
	$self->{dbg} && $self->Debug("$stale_time time is fresh, is_master $is_master", $master);
	0; # not master
    }
}

sub CleanupGroups {
    my($self, $force) = @_;
    return unless $self->{Session};

    my $cleanup = 0;
    my $state_dir = $self->{state_dir};
    $force ||= 0;

    $self->Debug("forcing groups cleanup") if ($self->{dbg} && $force);

    # each apache process has an internal time in which it 
    # did its last check, once we have passed that, we check
    # $Internal for the last time the check was done.  We
    # break it up in this way so that locking on $Internal
    # does not become another bottleneck for scripts
    if(($Apache::ASP::CleanupGroups{$state_dir} || 0) < time()) {
	$Apache::ASP::CleanupGroups{$state_dir} = time() + $self->{group_refresh}/4;
	$self->Debug("testing internal time for cleanup groups");
	my $internal = $self->{Internal};
	if($self->CleanupMaster) {
	    $internal->LOCK();
	    if($force || ($internal->{CleanupGroups} < time())) {
		$internal->{CleanupGroups} = time() + $self->{group_refresh};
		$cleanup = 1;
	    }
	    $internal->UNLOCK;
	}
    }
    return unless $cleanup;

    my $groups = $self->{Session}{_SELF}{'state'}->DefaultGroups();
    my($sum_active, $sum_deleted);
    for(@{$groups}) {	
	$sum_deleted = $self->CleanupGroup($_, $force);
    }
    $self->Debug("cleanup groups", { deleted => $sum_deleted }) if $self->{dbg};
    
    # boolean true at least for master
    $sum_deleted || 1; 
}

sub PrettyError {
    my($self) = @_;
    my $response = $self->{Response};

    my $out = $response->{out};
    $$out = $self->PrettyErrorHelper();
    $response->Flush();
	
    1;
}

sub PrettyErrorHelper {
    my $self = shift;

    my $response_buffer = $self->{Response}{out};
    $self->{Response}->Clear();
    my $errors_out = '';
    my @eval_error_lines;
    if($self->{errors_output}[0]) {
	$errors_out = join("\n<li> ", '', map { $self->Escape($_) } @{$self->{errors_output}});
	# link in the line number to the compiled program
	if($errors_out =~
	   s/(at.*?) line (\d+)/$1 \<a href\=\#$2>line $2\<\/a\>/) 
	  {
	      push(@eval_error_lines, $2);	      
	  }
    }
    my $out = <<OUT;
<tt>
<b><u>Errors Output</u></b>
<ol>
$errors_out
</ol>

<b><u>Debug Output</u></b>
<ol>
@{[join("\n<li> ", '', map { $self->Escape($_) } @{$self->{debugs_output}}) ]}
</ol>
</tt>
<pre>

OUT
    ;

    # could be looking at a compilation error, then set the script to what
    # we were compiling (maybe global.asa), else its our real script
    # with probably a runtime error
    my $script;     
    if($self->{compile_error}) {    
	$out .= "<b><u>Compile Error</u></b>\n\n";
	$out .= $self->Escape($self->{compile_error}) . "\n";
	$script = $self->{compile_eval};
    }
    
    if($$response_buffer) {
	my $length = $self->{r}->dir_config('DebugBufferLength') || 100;
	$out .= "<b><u>Last $length Bytes of Buffered Output</u></b>\n\n";
	$out .= $self->Escape(substr($$response_buffer, -1 * $length));
	$out .= "\n\n";
    }

    my $lineno = 1;
    my $error_desc;
    if($script) {
	$error_desc = "Compiled Data with Error";
    } else {
	$error_desc = "ASP to Perl Script";
	$script = $Apache::ASP::Compiled{$self->{GlobalASA}{'package'}.'::'.$self->{id}}->{output};		 }    
    $out .= "<b><u>$error_desc</u></b><a name=1>&nbsp;</a>\n\n";

    for(split(/\n/, $script)) {
	my $lineprint = sprintf('%3d', $lineno);
	grep($lineno == $_, @eval_error_lines) && 
	  ($lineprint = "<b><font color=red>$lineprint</font></b>");
	unless($self->{'r'}->dir_config('CommandLine')) {
	    $_ = $self->Escape($_);
	}
	$out .= "<a name=".($lineno+1).">".$lineprint. "</a>: $_\n";
	$lineno++;
    }

    $out .= <<OUT;

</pre>
<hr width=30% size=1>\n<font size=-1>
<i> 
An error has occured with the Apache::ASP script just run. 
If you are the developer working on this script, and cannot work 
through this problem, please try researching the it at the 
<a href=http://www.nodeworks.com/asp/>Apache::ASP web site</a>,
specifically the <a href=http://www.nodeworks.com/asp/faq.html>FAQ section</a>.
Failing that, check out your 
<a href=http://www.nodeworks.com/asp/support.html>support options</a>, and 
if necessary include this debug output with any query. 

OUT
  ;

    $out;
}

sub Log {
    my($self, @msg) = @_;
    my $msg = join(' ', @msg);
    $msg =~ s/[\r\n]+/ \<\-\-\> /sg;
    $self->{r}->log_error("[asp] [$$] $msg");
}    

sub CompileError {
    my($self, $eval) = (shift, shift);
    $self->{compile_error} = $_[0] || 1;
    if(ref $eval) {
	$self->{compile_eval} = $$eval;
    } else {
	$self->{compile_eval} = $eval;
    }
    $self->Error(@_);
}

sub Error {
    my($self, $msg) = @_;
    
    my($package, $filename, $line) = caller;
    $msg .= ", $filename line $line";
    
    # error logging in $self
    $self->{errs}++;
    my $pretty_msg = $msg;
    $pretty_msg = $self->Escape($pretty_msg);
    $pretty_msg =~ s/\n/<br>/sg;

    push(@{$self->{errors_output}}, $msg);
    push(@{$self->{debugs_output}}, $msg);
    
    $self->Log("[error] $msg");
    
    1;
}   

# sub Debug { # for matching
*Debug = *Out; # default
sub Null {};
sub Out {
# already know because of aliasing
#    return unless $_[0]->{dbg};
    
    my($self, @args) = @_;
    my(@data, $arg);
    while(@args) {
	$arg = shift @args;
	my($ref, $data);
	if($ref = ref($arg)) {
	    if($arg =~ /HASH/) {
		$data = '';
		my $key;
		for $key (sort keys %{$arg}) {
		    my $value = $arg->{$key} || '';
		    $data .= "$key: $value; ";
		}
	    } elsif($arg =~ /ARRAY/) {
		$data = join('; ', @$arg);
	    } elsif($arg =~ /SCALAR/) {
		$data = $$arg;
	    } elsif($arg =~ /CODE/) {
		my $out = eval { &$arg };
		if($@) {
		    $data = $@;
		} else {
		    unshift(@args, $out);
		    next;
		}
	    } else {
		$data = $arg;
	    }
	} else {
	    $data = $arg;
	}
	push(@data, $data);
    }
	
    my $debug = join(' - ', @data);
    my $time = '';
#    if($self->{dbg} == 3) {
#	require Time::HiRes;
#	$time = Time::HiRes::time();
#	$time = " [$time]";
#    }
#    $self->Log("[debug]$time $debug");
    $self->Log("[debug] $debug");
    push(@{$self->{debugs_output}}, $debug);
    
    # someone might try to insert a debug as a scalar, better 
    # not to print anything
    undef; 
}

# combo get / set
sub SessionId {
    my($self, $id) = @_;

    if($id) {
	$self->{session_id} = $id;
	my $secure = $self->{secure_session} ? '; secure' : '';
	$self->{r}->header_out
	    ('Set-Cookie', 
	     "$Apache::ASP::SessionCookieName=$id; path=$self->{cookie_path}".$secure
	     );
    } else {
	# if we have already parsed it out, return now
	# quick session_id caching, mostly for use with 
	# cookie less url building
	$self->{session_id} && return $self->{session_id};

	my $session_cookie = 0;
	my $cookie = $self->{r}->header_in("Cookie") || '';
	my(@parts) = split(/\;\s*/, $cookie);
	for(@parts) {	
	    my($name, $value) = split(/\=/, $_, 2);
	    if($name eq $SessionCookieName) {
		$id = $value;
		$session_cookie = 1;
		$self->{dbg} && $self->Debug("session id from cookie: $id");
		last;
	    }
	}
	if(! $id && $self->{session_url}) {
	    $id = delete $self->{Request}{QueryString}{$SessionCookieName};	    
	    # if there was more than one session id in the query string, then just
	    # take the first one
	    ref($id) =~ /ARRAY/ and ($id) = @$id;
	    $id && $self->{dbg} && $self->Debug("session id from query string: $id");
	}

	# SANTIZE the id against hacking
	if($id) {
	    if(length($id) == $SessionIDLength and $id =~ /^[0-9a-z]+$/) {
		$self->{session_id} = $id;
	    } else {
		$self->Log("passed in session id $id failed checks sanity checks");
		$id = undef;		
	    }
	} 

	if($id) {
	    $self->{session_id} = $id;
	    $self->{session_cookie} = $session_cookie;
	}
    }

    $id;
}

sub Digest {
    my($self, $dataref) = @_;    
    my $md5 = $Apache::ASP::MD5;
    $md5->reset;
    $md5->add($$dataref);
    $md5->hexdigest();	    
}

sub Secret {
    my $self = shift;
    my $data = $self . $self->{remote_ip} . rand() . time() . 
      $Apache::ASP::MD5 . $self->{global} . $self->{'r'} . $self->{'filename'}. rand();
    $self->Digest(\$data);
}
    
sub Escape {
    my($self, $html) = @_;

    $html =~s/&/&amp;/g;
    $html =~s/\"/&quot;/g;
    $html =~s/>/&gt;/g;
    $html =~s/</&lt;/g;

    $html;
}

sub ParseXML {
    my($self, $dataref, $type) = @_;
    my $asp = $self;
    
    my $xml_dom;
    if($asp->{xslt_cache_size}) {
	my $cache;
	unless($cache = tied %Apache::ASP::XSLTCache) {
	    $asp->LoadModule('Cache', 'Tie::Cache');
	    $cache = tie %Apache::ASP::XSLTCache, 'Tie::Cache', $asp->{xslt_cache_size};
	}
	$cache->{max_count} = $asp->{xslt_cache_size};
	
	my $checksum = $asp->Digest($dataref);
	my $cache_key = $checksum.'_'.length($$dataref);
	$xml_dom = $Apache::ASP::XSLTCache{$cache_key};
	
	unless($xml_dom) {
	    if($cache->{count} >= $asp->{xslt_cache_size}) {
		# fetch from cache first to dispose, then delete
		my @keys = keys %Apache::ASP::XSLTCache;
		my $old_dom = $Apache::ASP::XSLTCache{$keys[0]};
		$old_dom->dispose;
		delete $Apache::ASP::XSLTCache{$keys[0]};			  
	    }
	    
	    eval {
		my $dom_parser = XML::DOM::Parser->new();
		$xml_dom = $dom_parser->parse($$dataref);
		$Apache::ASP::XSLTCache{$cache_key} = $xml_dom;
	    };
	    if($@) {
		$@ =~ s/^\s*//s;
		$asp->CompileError($$dataref, "Parse XML processing error: $@");
		return;
	    }       	
	} 
	
	$asp->{dbg} && $asp->Debug("parsexml $xml_dom, cache $cache, cache_key $cache_key");
    } else {
	eval {
	    my $dom_parser = XML::DOM::Parser->new();
	    $xml_dom = $dom_parser->parse($$dataref);
	};
	if($@) {
	    $@ =~ s/^\s*//s;
	    $asp->CompileError($$dataref, "Parse XML processing error: $@");
	    return;
	}       	
    }

    $xml_dom;
}

# Apache::StatINC didn't quite work right, so writing own
sub StatINC {
    my $self = shift;
    my $stats = 0;

    # include necessary libs, without nice error message...
    # we only do this once if successful, to speed up code a bit,
    # and load success bool into global. otherwise keep trying
    # to generate consistent error messages
    unless($StatINCReady) {
	my $ready = 1;
	for('Devel::Symdump', 'Apache::Symbol') {
	    eval "use $_";
	    if($@) {
		$ready = 0;
		$self->Error("You need $_ to use StatINC: $@ ... ".
			     "Please download it from your nearest CPAN");
	    }
	}
	$StatINCReady = $ready;
    }
    return unless $StatINCReady;
    
    # make sure that we have pre-registered all the modules before
    # this only happens on the first request of a new process
    unless($StatINCInit) {
	$StatINCInit = 1;
	$self->Debug("statinc init");
	$self->StatRegisterAll();	
    }

    while(my($key,$file) = each %INC) {
	if($self->{stat_inc_match} && defined $Apache::ASP::Stat{$file}) {
	    # we skip only if we have already registered this file
	    # we need to register the codes so we don't undef imported symbols
	    next unless ($key =~ /$self->{stat_inc_match}/);
	}

	next unless (-e $file); # sometimes there is a bad file in the %INC
	my $mtime = (stat($file))[9];

	# its ok if this block is CPU intensive, since it should only happen
	# when modules get changed, and that should be infrequent on a production site
	if(! defined $Apache::ASP::Stat{$file}) {
	    $self->Debug("loading symbols first time", { $key => $file});
	    $self->StatRegister($key, $file, $mtime);	    
	} elsif($mtime > $Apache::ASP::Stat{$file}) {
	    $self->Debug("reloading", {$key => $file});
	    $stats++; # count files we have reloaded
	    $self->StatRegisterAll();
	    
	    # we need to explicitly re-register a namespace that 
	    # we are about to undef, in case any imports happened there
	    # since last we checked, so we don't delete duplicate symbols
	    $self->StatRegister($key, $file, $mtime);

	    my $class = &Apache::Symbol::file2class($key);
	    my $sym = Devel::Symdump->new($class);

	    my $function;
	    my $is_global_package = $class eq $self->{GlobalASA}{'package'} ? 1 : 0;
	    for $function ($sym->functions()) { 
		my $code = \&{$function};

		if($function =~ /::O_[^:]+$/) {
		    $self->{dbg} && $self->Debug("skipping undef of troublesome $function");
		    next;
		}

		if($Apache::ASP::Codes{$code}{count} > 1) {
		    $self->{dbg} && $self->Debug("skipping undef of multiply defined $function: $code");
		    next;
		}	       

		if($is_global_package) {
		    # skip undef if id is an include or script 
		    if($Apache::ASP::CompiledIncludes{$function}) {
#			$self->Debug("$function is compiled include");
			next;
		    }
		    if($Apache::ASP::Compiled{$function}) {
#			$self->Debug("$function is compiled script");
			next;
		    }
		    if($Apache::ASP::ScriptSubs{$function}) {
			$self->Debug("$function is a script sub");
			next;
		    }

		}

		$self->{dbg} && $self->Debug("undef code $function: $code");
		&Apache::Symbol::undef($code);
		delete $Apache::ASP::Codes{$code};	       
	    }

	    # extract the lib, just incase our @INC went away
	    (my $lib = $file) =~ s/$key$//g;
	    push(@INC, $lib);

	    # don't use "use", since we don't want symbols imported into ASP
	    delete $INC{$key};
	    $self->Debug("loading $key with require");
	    eval { require($key); }; 
	    if($@) {
		$INC{$key} = $file; # make sure we keep trying to reload it
		$self->Error("can't require/reload $key: $@");
		next;
	    }

	    # if this was the same module as the global.asa package,
	    # then we need to reload the global.asa, since we just 
	    # undef'd the subs
	    if($is_global_package) {
		# we just undef'd the global.asa routines, so these too 
		# must be recompiled
		delete $Apache::ASP::Compiled{$self->{GlobalASA}{'id'}};
		&Apache::ASP::GlobalASA::new($self);
	    }

	    $self->StatRegister($key, $file, $mtime);

	    # we want to register INC now in case any new libs were
	    # added when this module was reloaded
	    $self->StatRegisterAll();
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

    # we skip Apache stuff as on some platforms (RedHat 6.0)
    # Apache::OK seems to error when getting its code ref
    # these shouldn't be reloaded anyway, as they are internal to 
    # modperl and should require a full server restart
    if($class eq 'Apache' or $class eq 'Apache::Constants') {
	$self->Debug("skipping StatINC register of $class");
	return;
    }

    $self->{dbg} && $self->Debug("stat register of $key $file $class");
    if($class eq 'CGI') {
	# must compensate for its autoloading behavior, and 
	# precompile all the routines, so we can register them
	# and not delete them later
	CGI->compile(':all');
    }

    my $sym = Devel::Symdump->new($class);
    my $function;
    for $function ($sym->functions()) {
	my $code = \&{$function};
	unless($code =~ /CODE/) {
	    $self->Debug("no code ref for function $function");
	    next;
	}

	# don't update if we already have this code defined for this func.
	next if $Apache::ASP::Codes{$code}{funcs}{$function}; 

#	$self->Debug("code $code for $function");
	$Apache::ASP::Codes{$code}{count}++;
	$Apache::ASP::Codes{$code}{libs}{$key}++;
	$Apache::ASP::Codes{$code}{funcs}{$function}++;
    }

    1;
}

sub StatRegisterAll {
    my $self = shift;
    # we make sure that all modules that are loaded are registered
    # so we don't undef exported subroutines, when we reload 
    my($key, $file);
    while(($key,$file) = each %INC) {
	next if defined $Apache::ASP::Stat{$file};
	next unless -e $file;
	# we use the module load time to init, in case it was
	# pulled in with PerlModule, and has changed since,
	# so it won't break with a graceful restart
	$self->StatRegister($key, $file, $Apache::ASP::StartTime - 1);
    }

    1;
}

sub SendMail {
    my($self, $mail, %args) = @_;
    my($smtp, @to, $server);
    my $rv = 1;

    # load option mail modules
    for('Net::Config', 'Net::SMTP') {
	eval "use $_";
	if($@) {
	    $self->Error("no mailing errors because can't load $_: $@");
	    return 0;
	}
    }
    
    # configure mail host
    if($self->{mail_host} = $self->{r}->dir_config('MailHost')) {
	unless($NetConfig{smtp_hosts}->[0] eq $self->{mail_host}) {
	    unshift(@{$NetConfig{smtp_hosts}}, $self->{mail_host});
	}
    }
    $mail->{From} ||= $self->{r}->dir_config('MailFrom');
    
    for('To', 'Body', 'Subject', 'From') {
	$mail->{$_} ||
	  die("need $_ argument to send mail");
    }
    
    # debugging set in mail args, or general debugging
    if($mail->{Debug} || $self->{dbg}) {
	$args{Debug} = 1;
	delete $mail->{Debug};
    }

    # connect to server
    $smtp = Net::SMTP->new(%args);
    unless($smtp) {
	$self->Debug("can't connect to SMTP server with args ", \%args);
	return 0;
    } else {
	$self->Debug("connected to SMTP server with args ", \%args);
    }
    
    @to = (ref $mail->{To}) ? @{$mail->{To}} : (split(/\s*,\s*/, $mail->{To})); 
    $self->Debug("sending mail to: ".join(',', @to));
    ($mail->{From}) = split(/\s*,\s*/,$mail->{From}); # just the first one
    
    $smtp->mail($mail->{From});
    $smtp->to(@to);

    my($data);
    my $body = $mail->{Body};
    delete $mail->{Body};

    my %done;
    for('Subject', 'From', 'Reply-To', 'Organization', 'To', keys %$mail) {
	next unless $mail->{$_};
	next if $done{lc($_)}++;	
	my $add = ref($mail->{$_}) ? join(",", @{$mail->{$_}}) : $mail->{$_};
	$add =~ s/^[\n]*(.*?)[\n]*$/$1/;
	$data .= "$_: $add\n";
    }
    $data .= "\n" . $body;

    $smtp->data($data) || ($rv = 0);
    $smtp->quit();

    $rv && $self->Debug("mail sent successfully");
    $rv;
}

sub MailErrors {
    my $self = shift;
    
    # email during register cleanup so the user doesn't have 
    # to wait, and possible cancel the mail by pressing "STOP"
    $self->Log("registering error mail to $self->{mail_errors_to} for cleanup phase");
    $self->{Server}->RegisterCleanup
      ( 
       sub { 
	   for(1..3) {
	       my $form = $self->{Request}{Form};
	       my $query = $self->{Request}{QueryString};
	       my $vars = $self->{Request}{ServerVariables};
	       my $server = $self->{Server};
	       my $http_out = join("<br>\n  ", 
				   map { "$_= ".$server->HTMLEncode(substr($vars->{$_}, 0, 100)) } 
				   sort grep(/^HTTP_/, keys %$vars)
				  );
	       my $query_out = join("<br>\n  ", 
				    map { "$_= ".$server->HTMLEncode(substr($query->{$_}, 0, 100)) } 
				    sort keys %$query
				   );
	       my $form_out = join("<br>\n  ", 
				   map { "$_= ".$server->HTMLEncode(substr($form->{$_}, 0, 100)) } 
				   sort keys %$form 
				   );				   
	       my $body = <<BODY;	       			       
<table>
<tr><td><b> Global: </b><td> $self->{global}
<tr><td><b>   File: </b><td> $self->{filename}
<tr><td><b>     IP: </b><td> $vars->{REMOTE_ADDR}
<tr><td><b> HTTP_*: </b><td> $http_out
<tr><td><b>  Query: </b><td> $query_out
<tr><td><b>   Form: </b><td> $form_out
</table>
BODY
  ;
	       $body =~ s/\<td\>/\<td valign=top\>\<font size=-1\>/isg;
	       $body .= "\n".$self->PrettyErrorHelper(),

	       my $success = 
		 $self->SendMail
		   ({
		     To => $self->{mail_errors_to},
		     From => $self->{r}->dir_config('MailFrom') || $self->{mail_errors_to},
		     Subject => "Apache::ASP Errors for $ENV{SCRIPT_NAME}",
		     Body => $body,
		     'Content-Type' => 'text/html',
		    });	       
	       if($success) {
		   last;
	       } else {
		   $self->Error("can't send errors mail to $self->{mail_errors_to}");
	       }
	   }
       });
}    

sub MailAlert {
    my $self = shift;

    unless($self->{mail_alert_period}) {
	$self->{mail_alert_period} = $self->{r}->dir_config('MailAlertPeriod') || 20;
    }
    
    # if we have the internal database defined, check last time the alert was
    # sent, and if the alert period is up, send again
    if(defined $self->{Internal}) {
	my $time = time;
	if(defined $self->{Internal}{mail_alert_time}) {
	    my $alert_in = $self->{Internal}{mail_alert_time} + $self->{mail_alert_period} * 60 - $time;
	    if($alert_in <= 0) {
		$self->{Internal}{mail_alert_time} = $time;
	    } else {
		# not time to send an alert again
		$self->Debug("will alert again in $alert_in seconds");
		return 1;
	    }
	} else {
	    $self->{Internal}{mail_alert_time} = $time;
	}
    } else {
	$self->Log("mail alerts will be sent every time.  turn NoState off so that ".
		   "alerts can be sent only every $self->{mail_alert_period} minutes");
    }

    my $host = '';
    if($self->LoadModules('MailAlert', 'Net::Domain')) {
	$host = Net::Domain::hostname();	
    }
    
    # email during register cleanup so the user doesn't have 
    # to wait, and possible cancel the mail by pressing "STOP"
    $self->Log("registering alert mail to $self->{mail_alert_to} for cleanup phase");

    $self->{Server}->RegisterCleanup
      ( 
       sub { 
	   for(1..3) {
	       my $success = 
		 $self->SendMail({
				  To => $self->{mail_alert_to},
				  From => $self->{r}->dir_config('MailFrom') || $self->{mail_alert_to},
				  Subject => join('-', 'ASP-ALERT', $host), 
				  Body => "$self->{global}-$ENV{SCRIPT_NAME}",				 
				 });
	       
	       if($success) {
		   last;
	       } else {
		   $self->Error("can't send alert mail to $self->{mail_alert_to}");
	       }
	   }
       });
}

*LoadModule = *LoadModules;
sub LoadModules {
    my($self, $category, @modules) = @_;
    my $load_errors = 0;
    
    for(@modules) {
	if(defined $LoadedModules{$_}) {
	    if($LoadedModules{$_} == 0) {
		if($LoadModuleErrors{$category}) {
		    $self->Error("cannot load $_ for $category: $LoadModuleErrors{$category}; $@");
		} else {
		    $self->Debug("already failed to load $_");
		}
		$load_errors++;
	    } 
	    next;
	}

	$_ =~ /^(.*)$/; # untaint
	eval "use $1";
	if($@) { 
	    if($LoadModuleErrors{$category}) {
		$self->Error("cannot load $_ for $category: $LoadModuleErrors{$category}; $@");
	    } else {
		$self->Log("cannot load $_ for $category: $@");
	    }
	    $load_errors++;
	    $LoadedModules{$_} = 0;
	} else {
	    $self->Debug("loaded module $_");
	    $LoadedModules{$_} = 1;
	}
    }
    
    ! $load_errors;
}

1;

package Apache::ASP::STDERR;

# alias printing to the response object
sub TIEHANDLE { bless { asp => $_[1] }; }
sub PRINT {
    shift->{asp}->Out(@_);
}
sub PRINTF {
    my($self, $format, @list) = @_;   
    my $output = sprintf($format, @list);
    $self->{asp}->Out($output);
}

1;

# GlobalASA Object
# global.asa processes, whether or not there is a global.asa file.
# if there is not one, the code is left blank, and empty routines
# are filled in
package Apache::ASP::GlobalASA;
use strict;
no strict qw(refs);
use vars qw(%stash *stash @ISA);

# these define the default routines that get parsed out of the 
# GLOBAL.ASA file
@Apache::ASP::GlobalASA::Routines = 
    (
     "Application_OnStart", 
     "Application_OnEnd", 
     "Session_OnStart", 
     "Session_OnEnd",
     "Script_OnStart",
     "Script_OnEnd",
     "Script_OnParse",
     "Script_OnFlush"
     );

sub new {
    my $asp = shift || die("no asp passed to GlobalASA");

    my $filename = $asp->{global}.'/global.asa';
    my $id = $filename;
    $id =~ s/\W/_/gs;
    my $package = $asp->{global_package} ? $asp->{global_package} : "Apache::ASP::Compiles".'::'.$id;

    my $self = bless { 
	asp => $asp,
#	filename => $filename,
	id => $id,
	'package' => $package,
    };

    # assign early, since something like compiling reference the global asa,
    # and we need to do that in here
    $asp->{GlobalASA} = $self;

    $asp->{dbg} && $asp->Debug("GlobalASA package $self->{'package'}");
    my $compiled = $Apache::ASP::Compiled{$id};
    if($compiled && ! $asp->{stat_scripts}) {
	$asp->{dbg} && $asp->Debug("no stat: GlobalASA already compiled");
	$self->{'exists'} = $compiled->{'exists'};
	$self->{'compiled'} = $compiled; # for event lookups
	return $self;
    }

    unless($compiled) {
	$compiled = $Apache::ASP::Compiled{$id} = { mtime => 0, 'exists' => 0 };
    }
    $self->{compiled} = $compiled;
    
    my $exists = $self->{'exists'} = -e $filename;
    my $changed = 0;
    if(! $exists && ! $compiled->{'exists'}) {
	# fastest exit for simple case of no global.asa
	return $self;
    } elsif(! $exists && $compiled->{'exists'}) {
	# if the global.asa disappeared
	$changed = 1;
    } elsif($exists && ! $compiled->{'exists'}) {
	# if global.asa reappeared
	$changed = 1;
    } else {
	$self->{mtime} = $exists ? (stat($filename))[9] : 0;
	if($self->{mtime} >= $compiled->{mtime}) {
	    # if the modification time is greater than the compile time
	    $changed = 1;
	} 
    }
    $changed || return($self);

    my $code = $exists ? $asp->ReadFile($filename) : "";
    my $strict = $asp->{use_strict} ? "use strict" : "no strict";
    $code =~ s/\<\/?script?.*?\>/\#script tag removed here/igs;
    $code = join(" ;; ",
		 "package $self->{'package'};",
		 $strict,
		 "use vars qw(\$".join(" \$",@Apache::ASP::Objects).');',
		 "use lib qw($self->{asp}->{global});",
		 $code,
		 'sub exit { $main::Response->End(); } ',
		 '1;',
		 );

    $asp->Debug("compiling global.asa $self->{'package'} $id", $self);
    $code =~ /^(.*)$/s; # untaint

    # only way to catch strict errors here
    if($asp->{use_strict}) { 
	local $SIG{__WARN__} = sub { die("maybe use strict error: ", @_) };
	eval $1;
    } else {
	eval $1;
    }

    # if we have success compiling, then update the compile time
    if(! $@) {
	# if file mod times are bad, we need to use them anyway
	# for relative comparison, time() was used here before, but
	# doesn't work
	$compiled->{mtime} = $self->{mtime} || (stat($filename))[9];
	
	# remember whether the file really exists
	$compiled->{'exists'} = $exists;
	
	# we cache whether the code was compiled so we can do quick
	# lookups before executing it
	my $routines = {};
	local *stash = *{"$self->{'package'}::"};
	for(@Apache::ASP::GlobalASA::Routines) {
	    if($stash{$_}) {
		$routines->{$_} = 1;
	    }
	}
	$compiled->{'routines'} = $routines;
	$asp->Debug('global.asa routines', $routines);
	$self->{'compiled'} = $compiled;
    } else {
	$asp->CompileError($code, "errors compiling global.asa: $@");
    }

    $self;
}

sub IsCompiled {
    my($self, $routine) = @_;
    $self->{'compiled'}{routines}{$routine};
}

sub Execute {
    my($self, $routine) = @_;
    if($self->{'compiled'}{routines}{$routine}) {
	$self->{'asp'}->Execute($routine);
    }
}

sub SessionOnStart {
    my $self = shift;
    my $asp = $self->{asp};
    my $zero_sessions = 0;

    if($asp->{session_count}) {
	$asp->{Internal}->LOCK();
	my $session_count = $asp->{Internal}{SessionCount} || 0;
	if($session_count <= 0) {
	    $asp->{Internal}{SessionCount} = 1;	
	    $zero_sessions = 1;
	} else {
	    $asp->{Internal}{SessionCount} = $session_count + 1;
	}
	$asp->{Internal}->UNLOCK();
    }

    #X: would like to run application startup code here after
    # zero sessions is true, but doesn't seem to account for 
    # case of busy server, then 10 minutes later user comes in...
    # since group cleanup happens after session, Application
    # never starts.  Its only when a user times out his own 
    # session, and comes back that this code would kick in.
    
    $asp->Debug("Session_OnStart", {session => $asp->{Session}->SessionID});
    $self->Execute('Session_OnStart');
}

sub SessionOnEnd {
    my($self, $id) = @_;
    my $asp = $self->{asp};
    my $internal = $asp->{Internal};

    # session count tracking
    if($asp->{session_count}) {
	$internal->LOCK();
	if((my $count = $internal->{SessionCount}) > 0) {
	    $internal->{SessionCount} = $count - 1;
	} else {
	    $internal->{SessionCount} = 0;
	}	    
	$internal->UNLOCK();
    }

    my $old_session = $asp->{Session};
    my $dead_session;
    if($id) {
	$dead_session = &Apache::ASP::Session::new($asp, $id);
	$asp->{Session} = $dead_session;
    } else {
	$dead_session = $old_session;
    }
       
    $asp->Debug("Session_OnEnd", {session => $dead_session->SessionID()});
    $self->Execute('Session_OnEnd');
    $asp->{Session} = $old_session;
    
    if($id) {
	untie %{$dead_session};
    } 

    1;
}

sub ApplicationOnStart {
    my $self = shift;
    $self->{asp}->Debug("Application_OnStart");
    %{$self->{asp}{Application}} = (); 
    $self->Execute('Application_OnStart');
}

sub ApplicationOnEnd {
    my $self = shift;
    my $asp = $self->{asp};
    $asp->Debug("Application_OnEnd");
    $self->Execute('Application_OnEnd');
    %{$self->{asp}{Application}} = (); 

    # PROBLEM, since we are not resetting ASP objects
    # every execute now, useless code anyway

    #    delete $asp->{Internal}{'application'};    
    #    local $^W = 0;
    #    my $tied = tied %{$asp->{Application}};
    #    untie %{$asp->{Application}};
    #    $tied->DESTROY(); # call explicit DESTROY
    #    $asp->{Application} = &Apache::ASP::Application::new($self->{asp})
    #      || $self->Error("can't get application state");
}

sub ScriptOnStart {
    my $self = shift;
    $self->{asp}{dbg} && $self->{asp}->Debug("Script_OnStart");
    $self->Execute('Script_OnStart');
}

sub ScriptOnEnd {
    my $self = shift;
    $self->{asp}{dbg} && $self->{asp}->Debug("Script_OnEnd");
    $self->Execute('Script_OnEnd');
}

sub ScriptOnFlush {
    my $self = shift;
    $self->{asp}{dbg} && $self->{asp}->Debug("Script_OnFlush");
    $self->Execute('Script_OnFlush');
}

1;

# Request Object
package Apache::ASP::Request;

sub new {
    my $asp = shift;
    my $r = $asp->{r};

    my $self = bless 
      { 
       asp => $asp,
#       content => undef,
#       Cookies => undef,
#       FileUpload => undef,
#       Form => undef,
#       QueryString => undef,
#       ServerVariables => undef,
       TotalBytes => 0,
      };
    
    # set up the environment, including authentication info
    # only copy %ENV if we are changing anything
    my $env; 
    if(defined $r->get_basic_auth_pw) {
	$env = { %ENV };
	my $c = $r->connection;
	#X: this needs to be extended to support Digest authentication
	$env->{AUTH_TYPE} = $c->auth_type;
	$env->{AUTH_USER} = $c->user;
	$env->{AUTH_NAME} = $r->auth_name;
	$env->{REMOTE_USER} = $c->user;
	$env->{AUTH_PASSWD} = $r->get_basic_auth_pw;
    } 
    $env ||= \%ENV;
    $self->{'ServerVariables'} = bless $env, 'Apache::ASP::Collection';

    # assign no matter what so Form is always defined
    my $form = {};
    my %upload;
    if(($r->method() || '') eq 'POST') {	
	if($ENV{CONTENT_TYPE}=~ m|^multipart/form-data|) {
	    if($asp->{file_upload_max} = $r->dir_config('FileUploadMax')) {
		$CGI::POST_MAX = $r->dir_config('FileUploadMax');		
	    }
	    if($asp->{file_upload_temp} = $r->dir_config('FileUploadTemp')) {
		eval "use CGI;";
	    } else {
		# default leaves no temp files for prying eyes
		eval "use CGI qw(-private_tempfiles);";		
	    }

	    if($@) { 
		$self->{asp}->Error("can't use file upload without CGI.pm: $@");
	    } else {		
		my %form;
		my $q = $self->{cgi} = new CGI;
		for(my @names = $q->param) {
		    $form{$_} = $q->param($_);
		    if(ref($form{$_}) eq 'Fh') {
			my $fh = $form{$_};
			binmode $fh if ($^O =~ /Win32/);
			$upload{$_} = $q->uploadInfo($fh);
			if($asp->{file_upload_temp}) {
			    $upload{$_}{TempFile} = $q->tmpFileName($fh);
			    $upload{$_}{TempFile} =~ s|^/+|/|;
			}
			$upload{$_}{BrowserFile} = $fh;
			$upload{$_}{FileHandle} = $fh;
			$upload{$_}{ContentType} = $upload{$_}{'Content-Type'};
			# tie the file upload reference to a collection... %upload
			# may be many file uploads note.
			$upload{$_} = bless $upload{$_}, 'Apache::ASP::Collection';
		    }
		}
		$form = \%form;
	    }
	} else {
	    # Only tie to STDIN if we have cached contents
	    # don't untie *STDIN until DESTROY, so filtered handlers
	    # have an opportunity to use any cached contents that may exist
	    $self->{content} = $r->content();
	    tie(*STDIN, 'Apache::ASP::Request', $self)
	      if defined($self->{content});	    
	    $form = $self->{content} ? $self->ParseParams(\$self->{content}) : {};
	}
	$self->{TotalBytes} = $ENV{CONTENT_LENGTH};
    } 

    $self->{'Form'} = bless $form, 'Apache::ASP::Collection';
    $self->{'FileUpload'} = bless \%upload, 'Apache::ASP::Collection';
    my $query = $r->args();
    my $parsed_query = $query ? $self->ParseParams(\$query) : {};
    $self->{'QueryString'} = bless $parsed_query, 'Apache::ASP::Collection';

    # do cookies now
    my %cookies; 
    if($r->header_in('Cookie')) {
	my @parts = split(/;\s*/, ($r->header_in('Cookie') || ''));
	for(@parts) {	
	    my($name, $value) = split(/\=/, $_, 2);
	    $name = &Unescape($self, $name);
	    
	    next if ($name eq $Apache::ASP::SessionCookieName);
	    next if $cookies{$name}; # skip dup's
	    
	    $cookies{$name} = ($value =~ /\=/) ? 
	      $self->ParseParams($value) : &Unescape($self, $value);
	}
    }
    $self->{Cookies} = bless \%cookies, 'Apache::ASP::Collection';

    $self;
}

sub DESTROY {
    my $self = shift;

    if($self->{cgi}) {
	# make sure CGI file handles are freed
	$self->{cgi}->DESTROY();
	$self->{cgi} = undef;
    }

    for(keys %{$self->{FileUpload}}) {
	my $upload = $self->{FileUpload}{$_};
	$self->{Form}{$_} = undef;
	if($upload->{FileHandle}) {
	    close $upload->{FileHandle};
	    # $self->{asp}->Debug("closing fh $upload->{FileHandle}");
	}
	$self->{FileUpload}{$_} = undef;
    }
}

# just returns itself
sub TIEHANDLE { $_[1] };

# just spill the cache into the scalar, so multiple reads are
# fine... whoever is reading from the cached contents must
# be reading the whole thing just once for this to work, 
# which is fine for CGI.pm
sub READ {
    my $self = $_[0];
    $_[1] ||= '';
    $_[1] .= $self->{content};
    $self->{ServerVariables}{CONTENT_LENGTH};
}

# COLLECTIONS, normal, Cookies are special, with the dictionary lookup
# directly aliased as this should be faster than autoloading
sub Form 
  { shift->{Form}->Item(@_) }
sub FileUpload 
  { shift->{FileUpload}->Item(@_) }
sub QueryString 
  { shift->{QueryString}->Item(@_) }
sub ServerVariables 
  { shift->{ServerVariables}->Item(@_) }

sub BinaryRead {
    my($self, $length) = @_;
    my $data;
    if($self->{TotalBytes}) {
	if(defined $length) {
	    substr($self->{content}, 0, $length);
	} else {
	    $self->{content}
	}
    } else {
	undef;
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
	if(ref $cookie && wantarray) {
	    return %$cookie;
	} else {
	    return $cookie;
	}
    }
}

sub ParseParams {
    my($self, $string) = @_;

    ($string = $$string) if ref($string); ## faster if we pass a ref for a big string
    $string ||= '';
    my @params = split /\&/, $string, -1;
    my %params;
#    if($self->{asp}{order_collections}) {
#	$self->{asp}->LoadModule('OrderCollections', 'Tie::IxHash');
#	tie %params, Tie::IxHash;
#    }

    # we have to iterate through the params here to collect multiple values for 
    # the same param, say from a multiple select statement
    my $pair;
    for $pair (@params) {
	my($key, $value) = map { &Unescape($self, $_) } split (/\=/, $pair, 2);
	if(defined $params{$key}) {
	    my $collect = $params{$key};

	    if(ref $collect) {
		# we have already collected more than one param for that key
		push(@{$collect}, $value);
	    } else {
		# this is the second value for a key we've seen, start array
		$params{$key} = [$collect, $value];
	    }
	} else {
	    # normal use, one to one key value pairs, just set
	    $params{$key} = $value;
	}
    }

    \%params;
}

# unescape URL-encoded data
sub Unescape {
    my $todecode = $_[1];
    $todecode =~ tr/+/ /;       # pluses become spaces
    $todecode =~ s/%([0-9a-fA-F]{2})/pack("c",hex($1))/ge;
    $todecode;
}

1;

# Response Object
package Apache::ASP::Response;
use strict;
no strict qw(refs);
use vars qw(@ISA %Members %LinkTags);
@ISA = qw(Apache::ASP::Collection);
use Carp qw(confess);

%Members = 
    (
     Buffer => 1,
     Clean => 1,
     ContentType => 1,
     Expires => 1,
     ExpiresAbsolute => 1,
     IsClientConnected => 1,
     Status => 1,
     );

# used for session id auto parsing
%LinkTags = (
	     'a' => 'href',
	     'area' => 'href',
	     'form' => 'action',
	     'frame' => 'src',
	     'iframe' => 'src',
	     'img' => 'src',
	     'input' => 'src',
	     'link' => 'href',
	    );

sub new {
    my $asp = shift;

    my $r = $asp->{'r'};
    my $out = '';

    return bless 
      {
       asp => $asp,
       out => \$out,
       # internal extension allowing various scripts like Session_OnStart
       # to end the same response
       #       Ended => 0, 
       CacheControl => 'private',
       CH => $r->dir_config('CgiHeaders') || 0, 
       #       Charset => undef,
       Clean => $r->dir_config('Clean') || 0,
       Cookies => bless({}, 'Apache::ASP::Collection'),
       ContentType => 'text/html',
       IsClientConnected => 1,
       #       PICS => undef,
       #       Status => 200,
       #       header_buffer => '', 
       #       header_done => 0,
       Buffer => defined $r->dir_config('BufferingOn') ? $r->dir_config('BufferingOn') : 1,
       BinaryRef => \$out,
       CompressGzip => ($asp->{compressgzip} and $ENV{HTTP_ACCEPT_ENCODING} =~ /gzip/io) ? 1 : 0,
       r => $r,
      };
}

sub DESTROY {}; # autoload doesn't have to skip it

# allow for deprecated use of routines that should be direct member access
sub AUTOLOAD {
    my($self, $value) = @_;
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

sub AddHeader { 
    my($self, $name, $value) = @_;   
    if($name =~ /^set\-cookie$/io) {
	$self->{r}->cgi_header_out($name, $value);
    } else {
	$self->{r}->header_out($name, $value);
    }
}   

sub AppendToLog { shift->{asp}->Log(@_); }
sub Debug { 
    my $self = shift;
    $self->{asp}{dbg} && $self->{asp}->Out("[$self->{asp}{basename}]", @_) 
};

sub BinaryWrite {
    $_[0]->Flush();
    $_[0]->{asp}{dbg} && $_[0]->{asp}->Out("binary write of ".length($_[1])." bytes");
    &Write;    
}

sub Clear { my $out = shift->{out}; $$out = ''; }

sub Cookies {
    my($self, $name, $key, $value) = @_;
    if(defined($name) && defined($key) && defined($value)) {
	$self->{Cookies}{$name}{$key} = $value;
    } elsif(defined($name) && defined($key)) {
	# we are assigning cookie with name the value of key
	if(ref $key) {
	    # if a hash, set the values in it to the keys values
	    # we don't just assign the ref directly since for PerlScript 
	    # compatibility
	    while(my($k, $v) = each %{$key}) {
		$self->{Cookies}{$name}{$k} = $v;
	    }
	} else {
	    $self->{Cookies}{$name}{Value} = $key;	    
	}
    } elsif(defined($name)) {
	# if the cookie was just stored as the name value, then we will
	# will convert it into its hash form now, so we can store other
	# things.  We will probably be storing other things now, since
	# we are referencing the cookie directly
	my $cookie = $self->{Cookies}{$name} || {};
	$cookie = ref($cookie) ? $cookie : { Value => $cookie };
	$self->{Cookies}{$name} = bless $cookie, 'Apache::ASP::Collection';	
    } else {
	$self->{Cookies};
    }
}

sub End {
    my $self = shift;
    &EndSoft($self);
    die('Apache::exit');
}

sub EndSoft {
    my $self = shift;
    return if $self->{Ended}++;

    $self->Flush();
}

sub Flush {
    my $self = shift;
    my $asp = $self->{asp};
    my $out = $self->{out};

    # Script_OnFlush event handler
    $asp->{GlobalASA}{'exists'} &&
      $asp->{GlobalASA}->ScriptOnFlush();
    
    # XSLT Processing
    if($asp->{xslt} && ! $asp->{errs}) {
	$self->FlushXSLT;
	return if $asp->{errs};
    }

    if($self->{Clean} and $self->{ContentType} eq 'text/html') {
	# by checking defined, we just check once
	unless(defined $Apache::ASP::CleanSupport) {
	    eval 'use HTML::Clean';
	    if($@) {
		$self->{asp}->Log("Error loading module HTML::Clean with Clean set to $self->{Clean}. ".
				  "Make user you have HTML::Clean installed properly. Error: $@");
		$Apache::ASP::CleanSupport = 0;
	    } else {
		$Apache::ASP::CleanSupport = 1;
	    }
	}

	# if we can't clean, we simply ignore	
	if($Apache::ASP::CleanSupport) {
	    my $h = HTML::Clean->new($out, $self->{Clean});
	    if($h) {
		$h->strip();
	    } else {
		$self->{asp}->Error("clean error: $! $@");
	    }
	}
    }

    ## Session query auto parsing for cookieless sessions
    if(
       $asp->{Session} 
       and ! $asp->{session_cookie} 
       and $asp->{session_url_parse} 
       and $self->{ContentType} eq 'text/html'
      ) 
      {
	  $self->SessionQueryParse();
      }

    # log total request time just once at the end
    # and append to html like Cocoon, per user request
    if($asp->{start_time} && $self->{Ended}) {
	if($self->{ContentType} eq 'text/html') {
	    my $total_time = sprintf('%7.2f', (&Time::HiRes::time() - $asp->{start_time})*1000);
	    $asp->{dbg} && $asp->Debug("page served in $total_time milliseconds");
	    if($asp->{r}->dir_config('Debug')) {
		$$out .= "\n<!-- Apache::ASP v".$Apache::ASP::VERSION.
		  " served page in $total_time milliseconds -->";
	    }
	}
    }

    # HEADERS AFTER CLEAN, so content-length would be calculated correctly
    # if this is the first writing from the page, flush a newline, to 
    # get the headers out properly
    if(! $self->{header_done}) {
	# if no headers and the script has ended, we know that the 
	# the script has not been flushed yet, which would at least
	# occur with buffering on
	if($self->{Ended}) {
            # gzip the buffer if CompressGzip && browser accepts it &&
            # the script is flushed once
            if($self->{CompressGzip} && $asp->LoadModule('Gzip','Compress::Zlib')) {
		$self->{r}->header_out('Content-Encoding','gzip');
		$$out = Compress::Zlib::memGzip($out);
	    }
	    
	    $self->{r}->header_out('Content-Length', length($$out));
	}
	
	$self->{header_done} = 1;
	&SendHeaders($self);
    }
    return unless $$out;

    if($asp->{filter}) {
	print STDOUT $$out;
    } else {
	#        unless($self->{r}->connection->aborted) {
	# OK to print random ouput for 200's & 300's
	if(! defined $self->{Status} or ($self->{Status} >= 200 and $self->{Status} < 400)) {
	    $self->{r}->print($$out);		
	}
	#	}
    }
    
    # supposedly this is more efficient than undeffing, since
    # the string does not let go of its allocated memory buffer
    $$out = ''; 
    
    1;
}

sub FlushXSLT {
    my $self = shift;
    my $asp = $self->{asp};
    my $out = $self->{BinaryRef};
    $asp->{xslt_cache_size} = $asp->{r}->dir_config('XSLTCacheSize');
    
    $asp->{xslt_match} = $asp->{r}->dir_config('XSLTMatch') || '^.';
    return unless ($asp->{filename} =~ /$asp->{xslt_match}/);

    # loading XSLT
    $asp->{dbg} && $asp->Debug("xslt processing with $asp->{xslt}");
    eval { require XML::XSLT; };
    if($@) {
	$asp->Error("failed to load XML::XSLT: $@");		
	return;
    }
	
    ## XSLT FETCH & CACHE
    my $xslt_dataref = $self->TrapInclude($asp->{xslt});
    $asp->Debug(length($$xslt_dataref), $xslt_dataref);
    return if($asp->{errs});

    my $xsl_dom = $asp->ParseXML($xslt_dataref);
    if($asp->{errs}) {
	$asp->Error("XSLT processing error for $asp->{xslt}: $@");
	return;
    }
	
    ## XSLT XML RENDER
    eval {
	my $xml_dom = $asp->ParseXML($out) || return;
	
	if($asp->{xslt_cache_size}) {		
	    # caching output
	    unless(tied %Apache::ASP::XSLTCacheOutput) {
		$asp->LoadModule('Cache', 'Tie::Cache');
		tie %Apache::ASP::XSLTCacheOutput, 'Tie::Cache', $asp->{xslt_cache_size};
	    }
	    my $cache_output = tied %Apache::ASP::XSLTCacheOutput;
	    $cache_output->{max_count} = $asp->{xslt_cache_size};
	    
	    my $cache_output_key = $xsl_dom.'_'.$xml_dom;
	    my $output_ref = $Apache::ASP::XSLTCacheOutput{$cache_output_key};
	    unless($output_ref) {
		my $xslt = XML::XSLT->new($xsl_dom, 'DOM');
		$xslt->transform_document($xml_dom, 'DOM');
		my $result = $xslt->result_tree;
		my $output = $result->toString;
		$result->dispose;
		$Apache::ASP::XSLTCacheOutput{$cache_output_key} = 
		  $output_ref = \$output;			
	    }
	    $$out = $$output_ref;
	} else {
	    my $xslt = XML::XSLT->new($xsl_dom, 'DOM');
	    $xslt->transform_document($xml_dom, 'DOM');
	    my $result = $xslt->result_tree;
	    $$out = $result->toString;
	    $result->dispose;
	    $xml_dom->dispose;
	    $xsl_dom->dispose;
	}
    };
    if($@) {
	$@ =~ s/^\s*//s;
	$asp->Error("XSLT/XML processing error: $@");
	return;
    }

    1;
}

# use the apache internal redirect?  Thought that would be counter
# to portability, but is still something to consider
sub Redirect {
    my($self, $location) = @_;
    my $asp = $self->{asp};

    &Clear($self);
    $asp->{dbg} && $asp->Debug('redirect called', {location=>$location});
    if($asp->{Session} and $asp->{session_url_parse}) {
	$location = &SessionQueryParseURL($self, $location);
	$asp->Debug("new location after session query parsing $location");
    }
       
    $self->{r}->header_out('Location', $location);
    $self->{Status} = 302;
    $self->{r}->status(302);
    &Flush($self);

    # if we have soft redirects, keep processing page after redirect
    unless($self->{r}->dir_config('SoftRedirect')) {
	&End($self);
    } else {
	$asp->Debug("redirect is soft");
    }

    1;
}

sub SendHeaders {
    my $self = shift;
    my $r = $self->{r};
    my $asp = $self->{asp};
    my $dbg = $asp->{dbg};
    my $status = $self->{Status};

    $dbg && $asp->Debug('building headers');
    $r->status($status) if defined($status);

    # for command line script
    return if $r->dir_config('NoHeaders');

    if(defined $status and $status == 401) {
	$dbg && $asp->Debug("status 401, note basic auth failure realm ".$r->auth_name);

	# we can't send out headers, and let Apache use the 401 error doc
	# But this is fine, once authorization is OK, then the headers
	# will go out correctly, so things like sessions will work fine.
	$r->note_basic_auth_failure;
	return;
    } else {
	$dbg && defined $status && $self->{asp}->Debug("status $status");
    }

    if(defined $self->{Charset}) {
	$r->content_type($self->{ContentType}.'; charset='.$self->{Charset});
    } else {
	$r->content_type($self->{ContentType}); # add content-type
    }

    if(%{$self->{'Cookies'}}) {
	&AddCookieHeaders($self);     # do cookies
    }

    # do the expiration time
    if(defined $self->{Expires}) {
	my $ttl = $self->{Expires};
	$r->header_out('Expires', &HTTP::Date::time2str(time()+$ttl));
	$self->{asp}->Debug("expires in $self->{Expires}");
    } elsif(defined $self->{ExpiresAbsolute}) {
	my $date = $self->{ExpiresAbsolute};
	my $time = &HTTP::Date::str2time($date);
	if(defined $time) {
	    $r->header_out('Expires', &HTTP::Date::time2str($time));
	} else {
	    confess("Response->ExpiresAbsolute(): date format $date not accepted");
	}
    }

    # do the Cache-Control header
    $r->header_out('Cache-Control', $self->{CacheControl});
    
    # do PICS header
    defined($self->{PICS}) && $r->header_out('PICS-Label', $self->{PICS});
    
    # don't send headers with filtering, since filter will do this for
    # all the modules once
    # doug sanctioned this one
    unless($r->header_out("Content-type")) {
	# if filtering, we don't send out a header from ASP
	# this means that Filtered scripts can use CGI headers
	# we order the test this way in case Ken comes on
	# board with setting header_out, in which case the test 
	# will fail early       
	if(! $asp->{filter} && (! defined $status or $status >= 200 && $status < 400)) {
	    $dbg && $asp->Debug("sending cgi headers");
	    if(defined $self->{header_buffer}) {
		# we have taken in cgi headers
		$r->send_cgi_header($self->{header_buffer} . "\n");
		$self->{header_buffer} = undef;
	    } else {	
		$r->send_http_header();
	    }
	}
    }

    1;
}

# do cookies, try our best to emulate cookie collections
sub AddCookieHeaders {
    my $self = shift;
    my $cookies = $self->{'Cookies'};

    my($cookie_name, $cookie);
    for $cookie_name (keys %{$cookies}) {
	# skip key used for session id
	if($Apache::ASP::SessionCookieName eq $cookie_name) {
	    confess("You can't use $cookie_name for a cookie name ".
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
	    
	    if($k eq 'secure' and $v) {
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
	    } elsif($k eq 'path') {
		$data[2] = "$k=$v";
	    } else {
		if(defined($cookie->{Value}) && ! (ref $cookie->{Value})) {
		    # if the cookie value is just a string, its not a dict
		} else {
		    # cookie value is a dict, add to it
		    $cookie->{Value}{$old_k} = $v;
		}			
	    } 
	}
	
	my $server = $self->{asp}{Server}; # for the URLEncode routine
	if(defined($cookie->{Value}) && (! ref $cookie->{Value})) {
	    $cookie->{Value} = $server->URLEncode($cookie->{Value});
	} else {
	    my @dict;
	    while(($k, $v) = each %{$cookie->{Value}}) {
		push(@dict, $server->URLEncode($k) 
		     . '=' . $server->URLEncode($v));
	    }
	    $cookie->{Value} = join('&', @dict);
	} 
	$data[0] = $server->URLEncode($cookie_name) . "=$cookie->{Value}";
	
	# have to clean the data now of undefined values, but
	# keeping the position is important to stick to the Cookie-Spec
	my @cookie;
	for(0..4) {	
	    next unless $data[$_];
	    push(@cookie, $data[$_]);
	}		
	my $cookie_header = join('; ', @cookie);
	$self->{r}->cgi_header_out("Set-Cookie", $cookie_header);
	$self->{asp}->Debug({cookie_header=>$cookie_header});
    }
}

# with the WriteRef vs. Write abstration, direct calls 
# to write might slow a little, but more common static 
# html calls to WriteRef will be saved the HTML copy
sub Write {
    my $self = shift;
    
    my $dataref;
    if(@_ > 1) {
	$, ||= ''; # non-standard use, so init here
	my $data = join($,, @_);
	$dataref = \$data;
    } else {
#	$_[0] ||= '';
	$dataref = defined($_[0]) ? \$_[0] : \'';
    }

    &WriteRef($self, $dataref);
}

*WR = *WriteRef;
sub WriteRef {
    my($self, $dataref) = @_;

    # allows us to end a response, but still execute code in event
    # handlers which might have output like Script_OnStart / Script_OnEnd
    return if $self->{Ended};
    my $content_out = $self->{out};

    # work on the headers while the header hasn't been done
    # and while we don't have anything in the buffer yet
    #
    # also added a test for the content type being text/html or
    # 
    if($self->{CH} && ! $self->{header_done} && ! $$content_out 
       && ($self->{ContentType} eq 'text/html')) 
    {
	# -1 to catch the null at the end maybe
	my @headers = split(/\n/, $$dataref, -1); 

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
		unless(defined $self->{header_buffer}) {
		    $self->{header_buffer} .= '';
		}
		$self->{header_buffer} .= "$out\n";
	    } else {
		unshift(@headers, $out);
		last;
	    }
	}
	
	# if we found some headers, pop the first entry off 
	# what to send @_ and continue
	if($self->{header_buffer}) {
	    if(defined $headers[0]) {
		$$dataref = join("\n", @headers);
	    } else {
		shift @_;
	    }
	}
    }

    # add dataref to buffer
    $$content_out .= $$dataref;
    
    # do we flush now?  not if we are buffering
    if(! $self->{Buffer}) {
	# we test for whether anything is in the buffer since
	# this way we can keep reading headers before flushing
	# them out
	&Flush($self);
    } 

    1;
}
*write = *Write;

# alias printing to the response object
sub TIEHANDLE { $_[1]; }
*PRINT = *Write;
sub PRINTF {
    my($self, $format, @list) = @_;   
    my $output = sprintf($format, @list);
    $self->Write($output);
}


sub Null {};
sub TrapInclude {
    my($self, $file) = @_;
    
    my $out = "";
    local $self->{out} = local $self->{BinaryRef} = \$out;
    local $self->{Ended} = 0;
    local *Apache::ASP::Response::Flush = *Null;
    $self->Include($file);

    \$out;
}

sub Include {    
    my $self = shift;
    my $file = shift;
    my $asp = $self->{asp};

    my $_CODE = $asp->CompileInclude($file);
    unless(defined $_CODE) {
	$asp->Error("error including $file, not compiled");
	return;
    }
    
    my $eval = $_CODE->{code};
    $asp->{dbg} && $asp->Debug("executing $eval");    

    my $rc = eval { &$eval(@_) };
    if($@) {
	my $code = $_CODE;
	die "error executing code for include $code->{file}: $@; compiled to $code->{perl}";
    }

    $rc;
}

sub ErrorDocument {
    my($self, $error_code, $uri) = @_;
    $self->{'r'}->custom_response($error_code, $uri); 
}

sub SessionQueryParse {
    my $self = shift;

    # OPTIMIZE MATCH: a is first in the sort, so this is fairly well optimized, 
    # putting img up at the front doesn't seem to make a different in the speed
    my $tags_grep = join('|', sort keys %LinkTags); 
    my $new_content = ''; # we are going to rebuild this content
    my $content_ref = $self->{out};
    my $asp = $self->{asp};    
    $asp->Debug("parsing session id into url query strings");

    # update quoted links in script location.href settings too
    # if not quoted, then maybe script expressions
    $$content_ref =~ 
      s/(\<script.*?\>[^\<]*location\.href\s*\=[\"\'])([^\"\']+?)([\"\'])
	/$1.&SessionQueryParseURL($self, $2).$3
	  /isgex;
    
    while(1) {
	# my emacs perl mode doesn't like ${$doc->{content}}
	last unless ($$content_ref =~ s/
		     ^(.*?)               # html head 
		     \<                   # start
		     \s*($tags_grep)\s+  # tag itself
		     ([^>]+)              # descriptors    
		     \>                   # end
		     //isxo
		     );
	
	my($head, $tag, $temp_attribs) = ($1, lc($2), $3);
	my $element = "<$2 $temp_attribs>";	
	my %attribs;
	
	while($temp_attribs =~ s/^\s*([^\s=]+)\s*\=?//so) {
	    my $key = lc $1;
	    my $value;
	    if($temp_attribs =~ s/^\s*\"([^\"]*)\"\s*//so) {
		$value = $1;
	    } elsif ($temp_attribs =~ s/^\s*\'([^\']*)\'\s*//so) {
		# apparently browsers support single quoting values
		$value = $1;
	    } elsif($temp_attribs =~ s/^\s*([^\s]*)\s*//so) {
		# sometimes there are mal-formed URL's
		$value = $1;
		$value =~ s/\"//sgo;
	    }
	    $attribs{$key} = $value;
	}
	
	# GET URL from tag attribs finally
	my $rel_url = $attribs{$LinkTags{$tag}};
#	$asp->Debug($rel_url, $element, \%attribs);
	if(defined $rel_url) {
	    my $new_url = &SessionQueryParseURL($self, $rel_url);
	    # escape all special characters so they are not interpreted
	    if($new_url ne $rel_url) {
		$rel_url =~ s/([\W])/\\$1/sg;
		$element =~ s|($LinkTags{$tag}\s*\=\s*[\"\']?)$rel_url|$1$new_url|isg;
#		$asp->Debug("parsed new element $element");
	    }
	}
	
	$new_content .= $head . $element;
    }
    
#    $asp->Debug($$content_ref);
    $new_content .= $$content_ref;
    $$content_ref = $new_content;
    1;
}

sub SessionQueryParseURL {
    my($self, $rel_url) = @_;
    my $asp = $self->{asp};    
    my $match = $asp->{session_url_parse_match};

    if(
       # if we have match expression, try it
       ($match && $rel_url =~ /$match/)
       # then if server path, check matches cookie space 
       || ($rel_url =~ m|^/| and $rel_url =~ m|^$asp->{cookie_path}|)
       # then do all local paths, matching NOT some URI PROTO
       || ($rel_url !~ m|^[^\?\/]+?:|)
      )
      {
	  my($query, $new_url);
	  if($rel_url =~ /^([^\?]+)\?(.*)$/) {
	      $new_url = $1;
	      $query = $2;
	  } else {
	      $new_url = $rel_url;
	      $query = '';
	  }
	  my $new_query = join('&', 
			       (map { 
				   /^$Apache::ASP::SessionCookieName\=/ ? 
				     '' : $_
				 } 
				split(/&/, $query)
			       ),
			       $Apache::ASP::SessionCookieName.'='.$asp->{session_id}
			      );
	  $new_url .= '?'.$new_query;
	  $asp->{dbg} && $asp->Debug("parsed session into $new_url");
	  $new_url;
      } else {
	  $rel_url;
      }
}

1;

# Server Object
package Apache::ASP::Server;

sub new {
    bless {asp => $_[0]};
}

sub CreateObject {
    my($self, $name) = @_;
    my $asp = $self->{asp};

    # dynamically load OLE at request time, especially since
    # at server startup, this seems to fail with "start_mutex" error
    unless(defined $Apache::ASP::OLESupport) {
	eval 'use Win32::OLE';
	if($@) {
	    $Apache::ASP::OLESupport = 0;
	} else {
	    $Apache::ASP::OLESupport = 1;
	}
    }

    unless($Apache::ASP::OLESupport) {
	die "OLE-active objects not supported for this platform, ".
	    "try installing Win32::OLE";
    }

    unless($name) {
	die "no object to create";
    }

    Win32::OLE->new($name);
}

sub Execute {
    my($self, $file) = (shift, shift);
    $self->{asp}{Response}->Include($file, @_);
}

sub Transfer {
    shift->Execute(shift);
    goto APACHE_ASP_EXECUTE_END;
}

# shamelessly ripped off from CGI.pm, by Lincoln D. Stein.
sub URLEncode {
    my $toencode = $_[1];
    $toencode =~ s/([^a-zA-Z0-9_\-.])/uc sprintf("%%%02x",ord($1))/esg;
    $toencode;
}

# shamelessly ripped off from CGI.pm, by Lincoln D. Stein.
sub HTMLEncode {
    my $toencode = $_[1];
    $toencode=~s/&/&amp;/sg;
    $toencode=~s/\"/&quot;/sg;
    $toencode=~s/>/&gt;/sg;
    $toencode=~s/</&lt;/sg;
    $toencode;
}

sub RegisterCleanup {
    my($self, $code) = @_;
    (ref($code) =~ /^CODE/) || 
	$self->{asp}->Error("$code need to be a perl sub reference, see README");
    push(@Apache::ASP::Cleanup, $code);
}

sub MapPath {
    my($self, $path) = @_;
    my $subr = $self->{asp}{r}->lookup_uri($path);
    $subr ? $subr->filename : undef;
}

*SendMail = *Mail;
sub Mail {
    shift->{asp}->SendMail(@_);
}

sub URL {
    my($self, $url, $params) = @_;
    
    my $asp = $self->{asp};
    if($asp->{session_url} && $asp->{session_id} && ! $asp->{session_cookie}) {
	my $match = $asp->{session_url_match};
	if(
	   # if we have match expression, try it
	   ($match && $url =~ /$match/)
	   # then if server path, check matches cookie space 
	   || ($url =~ m|^/| and $url =~ m|^$asp->{cookie_path}|)
	   # then do all local paths, matching NOT some URI PROTO
	   || ($url !~ m|^[^\?\/]+?:|)
	  ) 
	  {
	      # this should overwrite an incorrectly passed in data
	      $params->{$Apache::ASP::SessionCookieName} = $asp->{session_id};
	  }
    }

    my($k,$v, @query);
    while(($k, $v) = each %$params) {
	# inline the URLEncode function for speed
	$k =~ s/([^a-zA-Z0-9_\-.])/uc sprintf("%%%02x",ord($1))/egs;
	$v =~ s/([^a-zA-Z0-9_\-.])/uc sprintf("%%%02x",ord($1))/egs;
	push(@query, $k.'='.$v);
    }
    if(@query) {
	$url .= '?'.join('&', @query);
    }

    $url;
}

sub Config {
    my($self, $key, $value) = @_;
    
    if(defined $value) {
	$self->{asp}{r}->dir_config($key, $value);
    } else {
	$self->{asp}{r}->dir_config($key);
    }
}

1;

# Application Object
package Apache::ASP::Application;
use strict;
no strict qw(refs);
use vars qw(@ISA);
@ISA = qw(Apache::ASP::Collection Apache::ASP::State);
use Fcntl qw(:flock O_RDWR O_CREAT );

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

sub Lock { shift->LOCK };
sub UnLock { shift->UNLOCK };

sub SessionCount {
    my $asp = tied(%{$_[0]})->{asp};
    if($asp->{session_count}) {
	$asp->{Internal}{SessionCount};
    } else {
	undef;
    }
}

sub GetSession {
    my($self, $id) = @_;
    my $asp = tied(%$self)->{'asp'};
    unless(defined $id and $id) {
	$asp->Warn("session id not defined");
	return;
    }
    unless(length($id) == 32) {
	$asp->Warn("session id must be of length 32");
	return;
    }

    if($asp->{Session} and $asp->{Session}->SessionID() eq $id) {
	return $asp->{Session};
    } else {
	my $new_session = Apache::ASP::Session::new($asp, $id, O_RDWR, 'NOERR');
	if($new_session) {
	    $asp->{r}->register_cleanup(sub { $new_session->DESTROY });
	}
	$new_session;
    }
}

1;

# Session Object
package Apache::ASP::Session;
use strict;
no strict qw(refs);
use vars qw(@ISA);
@ISA = qw(Apache::ASP::Collection);

# allow to pass in id so we can cleanup other sessions with 
# the session manager
sub new {
    my($asp, $id, $perms, $no_error) = @_;
    my($state, %self, $started);

    # if we are passing in the id, then we are doing a 
    # quick session lookup and can bypass the normal checks
    # this is useful for the session manager and such
    if($id) {
	$state = Apache::ASP::State::new($asp, $id, undef, $perms, $no_error);
	#	$state->Set() || $asp->Error("session state get failed");
	if($state) {
	    tie %self, 'Apache::ASP::Session', 
	    {
	     state=>$state, 
	     asp=>$asp, 
	     id=>$id,
	    };
	    return bless \%self;
	} else {
	    return;
	}
    }

    # lock down so no conflict with garbage collection
    my $internal = $asp->{Internal};
    $internal->LOCK();
    if($id = $asp->SessionId()) {
	my $idata = $internal->{$id};
#	$asp->Debug("internal data for session $id", $idata);
	if($idata) {
	    # user is authentic, since the id is in our internal hash
	    if($idata->{timeout} > time()) {
		# refresh and unlock as early as possible to not conflict 
		# with garbage collection
		$asp->RefreshSessionId($id);
		$state = Apache::ASP::State::new($asp, $id);
		$internal->UNLOCK();

		# session not expired
		$asp->{dbg} && 
		  $asp->Debug("session not expired",{'time'=>time(), timeout=>$idata->{timeout}});

		# Assume it was created before, no errors, and don't get now, since it will be
		# created later with the State WriteLock()
#		unless($state->Get('NO_ERROR')) {
#		    $asp->Log("session not timed out, but we can't tie to old session! ".
#			      "report this as an error with the relevant log information for this ".
#			      "session.  We repair the session by default so the user won't notice."
#			      );

#		    unless($state->Set()) {
#			$asp->Error("failed to re-initialize session");
#		    }
#		}
		
		if($asp->{paranoid_session}) {
		    local $^W = 0;
		    # by testing for whether UA was set to begin with, we 
		    # allow a smooth upgrade to ParanoidSessions
		    $state->UserLock() if $asp->{session_serialize};
		    my $state_ua = $state->FETCH('_UA');
		    if(defined($state_ua) and $state_ua ne $asp->{'ua'}) {
			$asp->Log("[security] hacker guessed id $id; ".
				  "user-agent ($asp->{'ua'}) does not match ($state_ua); ".
				  "destroying session & establishing new session id"
				  );
			$state->Init();
			undef $state;
			goto NEW_SESSION_ID;		    
		    }
		}

		$started = 0;
	    } else {
		# expired, get & reset
		$asp->RefreshSessionId($id, {}); # mark so it won't be run while we are running
		$internal->UNLOCK();	      

		$asp->Debug("session timed out, clearing");
		$asp->{GlobalASA}->SessionOnEnd($id);
		$internal->LOCK();
		delete $internal->{$id};
		$asp->RefreshSessionId($id);
		$internal->UNLOCK();
		
		# we need to create a new state now after the clobbering
		# with SessionOnEnd
		$state = Apache::ASP::State::new($asp, $id);
		$state->Set() || $asp->Error("session state startup failed");
		$started = 1;
	    }
	} else {
	    # never seen before, maybe session garbage collected already
	    # or coming in from querystringed search engine

	    # wish we could do more 
	    # but proxying + nat prevents us from securing via ip address
	    goto NEW_SESSION_ID;
	}
    } else {
	# give user new session id, we must lock this portion to avoid
	# concurrent identical session key creation, this is the 
	# only critical part of the session manager

      NEW_SESSION_ID:
	my($trys);
	for(1..10) {
	    $trys++;
	    $id = $asp->Secret();

	    if($internal->{$id}) {
		$id = '';
	    } else {
		last;
	    }
	}

	$id && $asp->RefreshSessionId($id, {});
	$asp->{Internal}->UNLOCK();	

	$asp->Log("[security] secret algorithm is no good with $trys trys")
	    if ($trys > 3);
	$asp->Error("no unique secret generated")
	    unless $id;

	$asp->{dbg} && $asp->Debug("new session id $id");
	$asp->SessionId($id);

	$state = &Apache::ASP::State::new($asp, $id);
	$state->Set() || $asp->Error("session state set failed");

	if($asp->{paranoid_session}) {
	    $asp->Debug("storing user-agent $asp->{'ua'}");
	    $state->STORE('_UA', $asp->{'ua'});
	}
	$started = 1;
    }

    if(! $state) {
	$asp->Error("can't get state for id $id");
	return;
    }

    $state->UserLock() if $asp->{session_serialize};
    $asp->Debug("tieing session $id");
    tie %self, 'Apache::ASP::Session', 
    {
	state=>$state, 
	asp=>$asp, 
	id=>$id,
	started=>$started,
    };
    if($asp->{dbg}) {
	$state->UserLock();
	$asp->Debug("tied session", \%self);
	$state->UserUnLock();
    }
    if($started) {
	$asp->{dbg} && $asp->Debug("clearing starting session");
	%self = ();
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
    # avoid odd global destruction errors
    return unless tied($self->{state}); 
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

    # putting these comparisons in a regexp was a little
    # slower than keeping them in these 'eq' statements
    if($index eq '_SELF') {
	$self;
    } elsif($index eq '_STATE') {
	$self->{state};
    } elsif($index eq 'SessionID') {
	$self->{id};
    } elsif($index eq 'Timeout') {
	$self->Timeout();
    } else {
	$self->{state}->FETCH($index);
    }
}

sub STORE {
    my($self, $index, $value) = @_;
    if($index eq 'Timeout') {
	$self->Timeout($value);
    } else {	
	$self->{state}->STORE($index, $value);
    }
}

# firstkey and nextkey skip the _UA key so the user 
# we need to keep the ua info in the session db itself,
# so we are not dependent on writes going through to Internal
# for this very critical informatioh. _UA is used for security
# validation / the user's user agent.
sub FIRSTKEY {
    my $self = shift;
    my $value = $self->{state}->FIRSTKEY();
    if(defined $value and $value eq '_UA') {
	$self->{state}->NEXTKEY($value);
    } else {
	$value;
    }
}

sub NEXTKEY {
    my($self, $key) = @_;
    my $value = $self->{state}->NEXTKEY($key);
    if($value eq '_UA') {
	$self->{state}->NEXTKEY($value);
    } else {
	$value;
    }	
}

sub CLEAR {
    my $state = shift->{state};
    my $ua = $state->FETCH('_UA');
    my $rv = $state->CLEAR();
    $ua && $state->STORE('_UA', $ua);
    $rv;
}

sub SessionID {
    my $self = shift;
    my $real_self;
    if($real_self = $self->{_SELF}) {
	$self = $real_self;
    }
    $self->{id};
}

sub Timeout {
    my($self, $minutes) = @_;

    # I don't know why, but tied($self) didn't work in here
    my $real_self;
    if($real_self = $self->{_SELF}) {
	$self = $real_self;
    }

    if($minutes) {
	my($internal_session) = $self->{asp}{Internal}{$self->{id}};
	$internal_session->{refresh_timeout} = $minutes * 60;
	$internal_session->{timeout} = time() + $minutes * 60;
	$self->{asp}{Internal}{$self->{id}} = $internal_session;
    } else {
	my($refresh) = $self->{asp}{Internal}{$self->{id}}{refresh_timeout};
	$refresh ||= $self->{asp}{session_timeout};
	$refresh / 60;
    }
}    

sub Abandon {
    shift->Timeout(-1);
}

sub TTL {
    my $self = shift;
    $self = $self->{_SELF};
    # time to live is current timeout - time... positive means
    # session is still active, returns ttl in seconds
    my $timeout = $self->{asp}{Internal}{$self->{id}}{timeout};
    my $ttl = $timeout - time();
}

sub Started {
    my $self = shift;
    $self->{_SELF}{started};
}

# we provide these, since session serialize is not 
# the default... locking around writes will also be faster,
# since there will be only one tie to the database and 
# one flush per lock set
sub Lock { tied(%{$_[0]})->{state}->WriteLock(); }
sub UnLock { tied(%{$_[0]})->{state}->UnLock(); }

1;

package Apache::ASP::State;
use strict;
no strict qw(refs);
use vars qw(%DB %CACHE $UNLOCK $DefaultGroupIdLength);
use Fcntl qw(:flock O_RDWR O_CREAT);
$DefaultGroupIdLength = 2;

# Database formats supports and their underlying extensions
%DB = (
       SDBM_File => ['.pag', '.dir'],
       DB_File => ['']
       );
%CACHE = ();

# About locking, we use a separate lock file from the SDBM files
# generated because locking directly on the SDBM files occasionally
# results in sdbm store errors.  This is less efficient, than locking
# to the db file directly, but having a separate lock file works for now.
#
# If there is no $group given, then the $group will be extracted from
# the $id as the first 2 letters of that group.
#
# If the group and the id are the same length, then what was passed
# was just a group id, and the object is being created for informational
# purposes only.  So, we don't create a lock file in this case, as this
# is not a real State object
#
sub new {
    my($asp, $id, $group, $permissions, $no_error) = @_;

    if($id) {
	$id =~ /^(.*)$/; # untaint
	$id = $1;
    } else {
	$asp->Error("no id: $id passed into new State");
	return;
    }

    # default group is first 2 characters of id, simple hashing
    if($group) {
	$group =~ /^(.*)$/; # untaint
	$group = $1;
    } else {
	$id =~ /^(..)/;
	$group = $1;
    }

    unless($group) {
	$asp->Error("no group defined for id $id");
	return;
    }

    my $state_dir = $asp->{state_dir};
    my $group_dir = $state_dir.'/'.$group;
    my $lock_file = $group_dir.'/'.$id.'.lock';
    my $file = $group_dir.'/'.$id;

    # we only need SDBM_File for internal, and its faster so use it
    my($state_db, $state_serializer);
    if($id eq 'internal') {
	$state_db = $Apache::ASP::DefaultStateDB;
	$state_serializer = $Apache::ASP::DefaultStateSerializer;
    } else {	
	# don't get data for dummy group id sessions
	my $internal = length($id) > $DefaultGroupIdLength ? $asp->{Internal} : {};
	my $idata = $internal->{$id};
	if(! $idata->{state_db} || ! $idata->{state_serializer}) {
	    $state_db = $idata->{state_db} || $asp->{state_db} || $Apache::ASP::DefaultStateDB;
	    $state_serializer = $idata->{state_serializer} || 
	      $asp->{state_serializer} || $Apache::ASP::DefaultStateSerializer;
	    
	    # INIT StateDB && StateSerializer if hitting for the first time
	    # only if real id like a session id or application
	    if(length($id) > $DefaultGroupIdLength) {
		my $diff = 0;
		if(($idata->{state_db} || $Apache::ASP::DefaultStateDB) ne $state_db) {
		    $idata->{state_db} = $state_db;
		    $diff = 1;
		}
		if(($idata->{state_serializer} || $Apache::ASP::DefaultStateSerializer) ne $state_serializer) {
		    $idata->{state_serializer} = $state_serializer;
		    $diff = 1;
		}

		# do not set if we are just getting the state
		if(! $permissions || $permissions ne O_RDWR) {		    
		    if($diff) {
			$asp->Debug("setting internal data for state $id", $idata);
			$internal->{$id} = $idata;
		    }
		}
	    }
	} else {
	    # this state has already been created
	    $state_db = $idata->{state_db};
	    $state_serializer = $idata->{state_serializer};
	}
    }

    # if the application does an onend during this time, we want
    # to update the state configs it to the appropriate values
    if($group eq 'server' and $asp->{state_cache}) {	
	if(my $state = $CACHE{$file}) {
	    $asp->{dbg} && $asp->Debug("returning state $state from cache for $id $group");
	    $state->{asp} = $asp;
	    $state->{state_db} = $state_db;
	    $state->{state_serializer} = $state_serializer;
	    return $state;
	}
    }

    my $self = 
      bless {
	     asp=>$asp,
	     dbm => undef, 
	     'dir' => $group_dir,
	     'ext' => ['.lock'],	    
	     id => $id, 
	     file => $file,
	     group => $group, 
	     group_dir => $group_dir,
	     num_locks => 0,
	     lock_file => $lock_file,
	     lock_file_fh => $lock_file,
	     open_lock => 0,
	     state_db => $state_db,
	     state_serializer => $state_serializer,
	     state_dir => $state_dir,
	     total_locks => 0,
	     total_unlocks => 0,
	     write_locked => 0,
	    };
    
    push(@{$self->{'ext'}}, @{$DB{$self->{state_db}}});    
#    $self->{asp}->Debug("db ext: ".join(",", @{$self->{'ext'}}));

    # create state directory
    unless(-d $state_dir) {
	mkdir($state_dir, 0750) 
	    || $self->{asp}->Error("can't create state dir $state_dir");
    }

    if(! $permissions || $permissions ne O_RDWR) {		    
	# create group directory
	unless(-d $group_dir) {
	    if(mkdir($group_dir, 0750)) {
		$self->{asp}->Debug("creating group dir $group_dir");
	    } else {
		$self->{asp}->Error("can't create group dir $group_dir");	    
	    }
	}    	
    }
	
    # open lock file now, and once for performance
    # we skip this for $group_id eq $id since then this is 
    # just a place holder empty state object used 
    # for information purposes only
    if($permissions) {
	if($self->Do($permissions, $no_error)) {
	    if($group eq 'server' and $asp->{state_cache}) {
		$CACHE{$file} = $self;
	    }
	    $self->OpenLock unless ($group eq $id);
	} else {
	    return undef;
	}    
    } else {
	$self->OpenLock unless ($group eq $id);
    }

    $self;
}

sub Get {
    shift->Do(O_RDWR, @_);
}

sub Set {
    shift->Do(O_RDWR|O_CREAT, @_);
}

sub Init {
    my $self = shift;
    $self->Set() || return;
    $self->{dbm}->CLEAR();
    $self;
}

sub Do {
    my($self, $permissions, $no_error) = @_;

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

#    my @temp = ($MLDBM::UseDB, $MLDBM::Serializer);
#    $self->{state_db} =~ s/^//; # untaint
    
    local $MLDBM::UseDB = $self->{state_db};
    local $MLDBM::Serializer = $self->{state_serializer};
    # clear current tied relationship first, if any
    $self->{dbm} = undef; 
    local $SIG{__WARN__} = sub {};
    $self->{dbm} = &MLDBM::TIEHASH('MLDBM', $self->{file}, $permissions, 0640);
#    ($MLDBM::UseDB, $MLDBM::Serializer) = @temp;    

    if($self->{dbm}) {
	# used to have locking code here
#	if($self->{state_db} eq 'DB_File') {
#	    $self->{dbm}{cachesize} = 0;
#	}
    } else {
	unless($no_error) {
	    $self->{asp}->Error("Can't tie to file $self->{file}, $permissions, $! !! \n".
				"Make sure you have the permissions on the \n".
				"directory set correctly, and that your \n".
				"version of Data::Dumper is up to date. \n".
				"Also, make sure you have set Global to \n".
				"to a good directory in the config file."
				);
	}
    }

    $self->{dbm};
}

sub Delete {
    my $self = shift;
    my $count = 0;

    unless($self->{file}) {
	$self->{asp}->Error("no state file to delete");
	return;
    }

    # we open the lock file when we new, so must close
    # before unlinking it
    $self->CloseLock();
    
    # manually unlink state files
    # all the file extensions so a switched StateDB will collect too
    for('.pag', '.dir', '', '.lock') { 
#    for(@{$self->{'ext'}}) {
	my $unlink_file = $self->{file}.$_;
	next unless (-e $unlink_file);

	if(unlink($unlink_file)) {
	    $count++;
#	    $self->{asp}->Debug("deleted state file $unlink_file");
	} else {
	    $self->{asp}->Error("can't unlink state file $unlink_file: $!"); 
	    return;
	}
    }

    $count;
}

sub DeleteGroupId {
    my $self = shift;
  
    my $group_dir = $self->{group_dir};
    if(-d $group_dir) {
	if(rmdir($group_dir)) {
	    $self->{asp}->Debug("deleting group dir $group_dir");
	} else {
	    $self->{asp}->Log("cannot delete group dir $group_dir: $!");
	}
    }
}    

sub GroupId {
    shift->{group};
}

sub GroupMembers {
    my $self = shift;
    local(*DIR);
    my(%ids, @ids);

    unless(-d $self->{group_dir}) {
	$self->{asp}->Log("no group dir:$self->{group_dir} to get group from");
	return [];
    }

    unless(opendir(DIR, $self->{group_dir})) {
	$self->{asp}->Log("opening group $self->{group_dir} failed: $!");
	return [];
    }

    for(readdir(DIR)) {
	next if /^\.\.?$/;
	$_ =~ /^(.*?)(\.[^\.]+)?$/;
	next unless $1;
	$ids{$1}++;
    }
    # need to explicitly close directory, or we get a file
    # handle leak on Solaris
    closedir(DIR); 
    @ids = keys %ids;

    \@ids;
}

sub DefaultGroups {
    my $self = shift;
    my(@ids);
    local *STATEDIR;
    
    opendir(STATEDIR, $self->{state_dir}) 
	|| $self->{asp}->Error("can't open state dir $self->{state_dir}");
    for(readdir(STATEDIR)) {
	next if /^\./;
	next unless (length($_) eq $DefaultGroupIdLength);
	push(@ids, $_);
    }
    closedir STATEDIR;

    \@ids;
}    

sub DESTROY {
    my $self = shift;
    return unless %{$self};
    return if $self->{destroyed}++;

    if($self->{num_locks} > 1) {
	# we set num locks down to 1, so UnLock
	# really unlocks the lock file, instead
	# of just popping a lock off
	$self->{num_locks} = 1;
    }

    if($CACHE{$self->{file}}) {
	$self->{destroyed} = 0;
	$self->UnLock();
    } else {
	untie $self->{dbm} if $self->{dbm};
	$self->{dbm} = undef;
	$self->UnLock();
	$self->CloseLock();    
    }

    $self->{asp}{dbg} &&
    $self->{asp}->Debug(
		      "state $self->{id} locks: $self->{total_locks}, ".
		      "unlocks: $self->{total_unlocks}"
		     );
    $self->{total_locks} = $self->{total_unlocks} = 0;
}

# don't need to skip DESTROY since we have it defined
# return if ($AUTOLOAD =~ /DESTROY/);
sub AUTOLOAD {
    my $self = shift;
    my $AUTOLOAD = $Apache::ASP::State::AUTOLOAD;
    $AUTOLOAD =~ s/^(.*)::(.*?)$/$2/o;

    my $value;
    $self->WriteLock();
    $value = $self->{dbm}->$AUTOLOAD(@_);
    $self->UnLock();
    
    $value;
}

sub TIEHASH {
    my $type = shift;

    # dual tie contructor, if we receive a State object to tie
    # then just return it, otherwise construct a new object
    # before tieing
    if((ref $_[0]) =~ /State/) {
	$_[0];
    } else {	
	bless &new(@_), $type;
    }
}

# FIRSTKEY / NEXTKEY is what makes references like %array
# and each %array tick.  What we do is take a snapshot of
# the keys when first key is called and just pop from there
# assuming sequencing NEXTKEYS... I used this method
# for Tie::Cache and it works just fine.
sub FIRSTKEY {
    my $self = shift;
    my @keys;

    $self->WriteLock();
    my $key = $self->{dbm}->FIRSTKEY();
    while(defined $key) {
	push(@keys, $key);	
	$key = $self->{dbm}->NEXTKEY($key);
    }
    $self->UnLock();
    $self->{'keys'} = \@keys;
    shift @{$self->{'keys'}};
}

sub NEXTKEY {
    my $self = shift;
    shift @{$self->{'keys'}};
}

sub FETCH {
    my($self, $index) = @_;
    my $value;

    if($index eq '_FILE') {
	$value = $self->{file};
    } elsif($index eq '_SELF') {
	$value = $self;
    } else {
	$self->WriteLock();
	$value = $self->{dbm}->FETCH($index);
	$self->UnLock();
    }

    $value;
}

sub STORE {
    my $self = shift;

    $self->WriteLock();
    $self->{dbm}->STORE(@_);
    $self->UnLock();
}

sub LOCK { tied(%{(shift)})->WriteLock(); }
sub UNLOCK { tied(%{(shift)})->UnLock(); }

# the +> mode open a read/write w/clobber file handle.
# the clobber is useful, since we don't have to create
# the lock file first
sub OpenLock {
    my $self = shift;
    return if $self->{open_lock};

    my $lock_file = $self->{lock_file};
    $self->{open_lock} = 1;
    my $mode = (-e $lock_file) ? "+<" : "+>"; 
    $self->{asp}{dbg} && $self->{asp}->Debug("opening lock file $self->{lock_file}");
    open($self->{lock_file_fh}, $mode . $lock_file) 
      || $self->{asp}->Error("Can't open $self->{lock_file}: $!");
}

sub CloseLock { 
    my $self = shift;
    return if ($self->{open_lock} == 0);
    $self->{open_lock} = 0;
    # suppress errors, as this can screw up in global 
    # destruction sometimes; saw this with perl5.004_04, Linux 2.0.34
    local $^W = 0;
    close($self->{lock_file_fh});
}

sub WriteLock {
    my $self = shift;
    my $file = $self->{lock_file_fh};
    $self->{num_locks}++;

    if($self->{write_locked}) {
#	$self->{asp}->Log("writelock: already write locked $file");
	1;
    } else {
#	$self->{asp}->Log("write locking");
	$self->{write_locked} = 1;
	$self->{total_locks}++;
	local $^W = 0;
	my $rv = eval { flock($file, LOCK_EX) };
	if($rv) {
	    # success, typical, first test for speed
	} elsif($@ and $^O eq 'MSWin32') {
	    $self->{asp}->Debug("flock() doesn't work on this platform, likely Win95: $!");
	} else {
	    $self->{asp}->Error("can't write lock $file: $!");    
	}
	$self->Set();
    }
}

sub UnLock {
    my $self = shift;
    my $file = $self->{lock_file_fh};

    if(($self->{num_locks} == 1) and $self->{write_locked}) {
	# locks only work when they were locked before
	# we started erroring, because file locking will
	# will hang a system if locking doesn't work properly
	$self->{write_locked} = 0;
	$self->{total_unlocks}++;
	$self->{dbm} = undef;
	if(eval { flock($file, ($UNLOCK || LOCK_UN)) }) {
	    # unlock success
	} else {
	    local $^W = 0;
	    if($@ and $^O eq 'MSWin32') {
		$self->{asp}->Debug("flock() unlocking doesn't work on this platform, likely Win95: $!");
	    }  else {
		$self->{asp}->Debug("basic unlock of $file failed: $!");
		# we try a flock work around here for QNX
		my $err = $!;
		eval { $UNLOCK ||=&Fcntl::F_UNLCK; };
		if($UNLOCK) {
		    unless(flock($file, $UNLOCK)) {
			$self->{asp}->Error("Can't unlock $file even with backup flock: $err, $!");
		    }		
		} else {
		    $self->{asp}->Error("Can't unlock $file: $err");		
		}
	    }
	}
    } else {
	# don't debug about this, since we'll always get some
	# of these since we are a bit over zealous about unlocking
	# better to unlock to much than too little
    }

#    $self->{asp}->Log("unlock called with $self->{num_locks} acquired");
    $self->{num_locks} && $self->{num_locks}--;

    1;
}

*UserLock = *WriteLock;
*UserUnLock = *UnLock;

1;

# this package emulates an Apache request object with a CGI backend
package Apache::ASP::CGI;
use strict;
no strict qw(refs);
use vars qw($StructsDefined);
$StructsDefined = 0;

sub do_self {
    my %config = @_;
    my $r = &init($0, @ARGV);
    $r->dir_config('CgiDoSelf', 1);
    $r->dir_config('NoState', 0);

    # init passed in config
    for(keys %config) {
	$r->dir_config($_, $config{$_});
    }

#    $r->dir_config('Debug', -1);
    &Apache::ASP::handler($r);
}

sub init {
    my($filename, @args) = @_;
    $filename ||= $0;
    
    for('CGI.pm', 'Class/Struct.pm') {
	next if require $_;
	die("can't load the $_ library.  please make sure you installed it");
    }
    
    # we define structs here so modperl users don't incur a runtime / memory
    unless($StructsDefined) {
	$StructsDefined = 1;
	&Class::Struct::struct( 'Apache::ASP::CGI::connection' => 
			       { 
				   'remote_ip' => "\$",
				   'auth_type' => "\$",
				   'user' => "\$",
				   'aborted' => "\$",
			       }
			       );    
	
	&Class::Struct::struct( 'Apache::ASP::CGI' => 
			       {
				   'cgi'       =>    "\$",
				   'connection'=>'Apache::ASP::CGI::connection',
				   'content_type' => "\$",
				   'dir_config'=>    "\%",
				   'env'       =>    "\%",
				   'filename'  =>    "\$",
				   'get_basic_auth_pw' => "\$",
				   'header_in' =>    "\%",
				   'header_out'=>    "\%",
				   'method'    =>    "\$",
				   'sent_header' =>  "\$",
			       }
			       );
    }

    # create struct
    my $self = new();
    my $cgi;
    if(defined $ENV{GATEWAY_INTERFACE} and $ENV{GATEWAY_INTERFACE} =~ /cgi/i) {
	if($ENV{CONTENT_TYPE}=~ m|^multipart/form-data|) {
	    # let ASP pick it up later via CGI
	    $cgi = new CGI({});
	} else {
	    # reading form input here
	    $cgi = new CGI;
	}
    } else {
	$cgi = CGI->new({@args});
    }
    
    $self->cgi($cgi);
    $self->filename($filename);
    $self->header_in('Cookie', $ENV{HTTP_COOKIE});
    $self->connection->remote_ip($ENV{REMOTE_HOST} || $ENV{REMOTE_ADDR} || '0.0.0.0');
    $self->connection->aborted(0);
#    $self->dir_config('Global') || $self->dir_config('Global', '.');

    # we kill the state for now stuff for now, as it's just leaving .state
    # directories everywhere you run this stuff
    defined($self->dir_config('NoState')) || $self->dir_config('NoState', 1);

    $self->method($cgi->request_method());
    $self->{env} = \%ENV;
    $self->env('SCRIPT_NAME') || $self->env('SCRIPT_NAME', $filename);

    $self;
}
    
sub status { $_[0]->header_out('status', $_[1]); }
sub cgi_env { %{$_[0]->env} ; }
sub cgi_header_out {
    my($self, $name, $value) = @_;
    if($name =~ /^set\-cookie$/i) {
	my $cookie = $self->header_out('Set-Cookie');
	$cookie ||= [];
	if(ref $cookie) {
	    # if there is already an array of cookies, push another one
	    push(@$cookie, $value);
	} else {
	    $cookie = [$cookie, $value];
	}
	$self->header_out('Set-Cookie', $cookie);
    } else {
	$self->header_out($name, $value);
    }
}

sub send_http_header {
    my($self) = @_;
    my($k, $v, $header, $value);
    
    $self->sent_header(1);
    $header = "Content-Type: " .$self->content_type()."\n";
    my $headers = $self->header_out();
    while(($k, $v) = each %$headers) {
	next if ($k =~ /^content\-type$/i);
	if(ref $v) {
	    # if ref, then we have an array for cgi_header_out for cookies
	    for $value (@$v) {
		$header .= "$k: $value\n";
	    }
	} else {
	    $header .= "$k: $v\n";	    
	}
    }
    $header .= "\n";
 	
    $self->print($header);
}

sub send_cgi_header {
    my($self, $header) = @_;

    $self->sent_header(1);
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

    my(%params, @pieces);	
    my @params = $self->cgi()->param();
    for (@params) {
	$params{$_} = $self->cgi()->param($_);
	my @values = $self->cgi()->param($_);
	my $value;
	for $value (@values) {
	    push(@pieces, 
		 Apache::ASP::Server->URLEncode($_).'='.
		 Apache::ASP::Server->URLEncode($value)
		);
	}
    }
    
    if(wantarray) {
	%params;
    } else {
	join('&', @pieces);
    }
}
*content = *args;

sub log_error {
    my($self, @args) = @_;
    print STDERR @args, "\n";
}

sub register_cleanup { 1; } # do nothing as cgi will cleanup anyway
sub soft_timeout { 1; };

1;

package Apache::ASP::Collection;

sub Contents { 
    my($self, $key) = @_;
    
    if(defined $key) {
	$self->Item($key);
    } else {
	$self;
    }
}

sub Item {
    my($self, $key, $value) = @_;

    if(defined $value) {
	if(ref($self->{$key}) and $self->{$key} =~ /HASH/) {
	    # multi leveled collection go two levels down
	    $self->{$key}{$value};
	} else {
	    $self->{$key} = $value;	
	}
    } elsif(defined $key) {
	my $value = $self->{$key};	
	defined($value) || return $value;
	if(wantarray) {
	    (ref($value) =~ /ARRAY/o) ? @{$value} : $value;
	} else {
	    (ref($value) =~ /ARRAY/o) ? $value->[0] : $value;
	}
    } else {
	# returns hash to self by default, so compat with 
	# $Request->Form() & such null collection calls.
	$self;
    }
}

sub SetProperty {
    my($self, $property, $key, $value) = @_;
    if($property =~ /property/io) {
	# do this to avoid recursion
	die("can't get the property $property for $self");
    } else {
	$self->$property($key, $value);
    }
}	

sub GetProperty {
    my($self, $property, $key) = @_;
    if($property =~ /property/io) {
	# do this to avoid recursion
	die("can't get the property $property for $self");
    } else {
	$self->$property($key);
    }
}	
	
1;

package Apache::ASP::Loader;
use strict;
no strict qw(refs);
use vars qw(@Days @Months $AUTOLOAD);
@Days = qw(Sun Mon Tue Wed Thu Fri Sat);
@Months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

# we need a different class from Apache::ASP::CGI because we don't
# want to force use of CGI & Class::Struct when loading ASP in Apache
# also a nasty bug doesn't allow us to eval require's or use's, we 
# get a can't start_mutex

sub new {
    my($file) = @_;
    bless {
	filename => $file,
	remote_ip => '127.0.0.1',
	user => undef,
	method => 'GET',
	NoState => 1,
    };
}

sub AUTOLOAD {
    $AUTOLOAD =~ s/^(.*)::([^:]*)$/$2/;
    shift->{$AUTOLOAD};
}

sub log_error { 
    shift; 
    my @times = localtime;
    printf STDERR ('[%s %s %02d %02d:%02d:%02d %d] [error] '.join('', @_)."\n", 
		   $Days[$times[6]],
		   $Months[$times[4]],
		   $times[3],
		   $times[2],
		   $times[1],
		   $times[0],
		   $times[5] + 1900
		   );
}

sub dir_config {
    my($self, $key, $value) = @_;
    if(defined $value) {
	$self->{$key} = $value;
    } else {
	$self->{$key};
    }
}

sub connection { shift; }

1;


=pod

=head1 NAME

  Apache::ASP - Active Server Pages for Apache with mod_perl 

=head1 SYNOPSIS

  SetHandler perl-script
  PerlHandler Apache::ASP
  PerlSetVar Global /tmp/asp

=head1 DESCRIPTION

This perl module provides an Active Server Pages port to the 
Apache Web Server with perl as the host scripting language. 
Active Server Pages is a web application platform that originated 
with the Microsoft NT/IIS server.  Under Apache for Unix and Win32
platforms it allows a developer to create dynamic web applications 
with session management and embedded perl code.

=begin html

<b>Apache::ASP's features include:</b>

<ul>
<li> Natural and Powerful Scripting SYNTAX
<li> Rich OBJECTS Developer API
<li> Web Application EVENTS Model
<li> Modular SSI Decomposition, Code Sharing
<li> User SESSIONS, NFS Web Cluster Friendly
<li> XML/XSLT Rendering & Custom Tag Technology
<li> CGI Compatibility
<li> PERLSCRIPT Compatibility
<li> Great Open Source SUPPORT
</ul>

=end html

This module works under the Apache Web Server
with the mod_perl module enabled. See http://www.apache.org and
http://perl.apache.org for further information.

This is a portable solution, similar to ActiveState's PerlScript
for NT/IIS ASP.  Work has been done and will continue to make ports 
to and from this implementation as smooth as possible.

For Apache::ASP downloading and installation, please read 
the INSTALL section.  For installation troubleshooting
check the FAQ and the SUPPORT sections.

For database access, ActiveX, scripting languages, and other
miscellaneous issues please read the FAQ section.

=head1 WEBSITE

The Apache::ASP web site is at http://www.nodeworks.com/asp/
which you can also find in the ./site directory of 
the source distribution.

=head1 INSTALL

The latest Apache::ASP can be found at your nearest CPAN,
and also:

  http://www.perl.com/CPAN-local/modules/by-module/Apache/

As a perl user, you should make yourself familiar with 
the CPAN.pm module, and how it may be used to install
Apache::ASP, and other related modules.

Once you have downloaded it, Apache::ASP installs easily using 
the make or nmake commands as shown below.  Otherwise, just 
copy ASP.pm to $PERLLIB/site/Apache

  > perl Makefile.PL
  > make 
  > make test
  > make install

  * use nmake for win32

Please note that you must first have the Apache Web Server
& mod_perl installed before using this module in a web server
environment.  The offline mode for building static html may
be used with just perl.

=head2 Need Help

Often, installing the mod_perl part of the Apache server
can be the hardest part.  If this is the case for you, 
check out the FAQ and SUPPORT sections
for further help.

=head2 RedHat Issues

If you have a RedHat Linux server with an RPM style 
Apache + mod_perl, seriously consider building a static version 
of the httpd server yourself, not DSO.  DSO is marked as 
experimental for mod_perl, and often does not work,
resulting in "no request object" error messages.

=head2 Quick Start

Once you have successfully built the Apache Web Server with mod_perl,
copy the ./site/eg/ directory from the Apache::ASP installation 
to your Apache document tree and try it out!  You must put "AllowOverride All"
in your httpd.conf <Directory> config section to let the .htaccess file in the 
./site/eg installation directory do its work.  If you want a starter
config file for Apache::ASP, just look at the .htaccess file in the 
./site/eg/ directory.

You will know that Apache::ASP is working normally if you 
can run the scripts in ./site/eg/ without any errors.

=head1 CONFIG

You may use a generic <Location> directive in your httpd.conf 
Apache configuration file to make Apache::ASP start ticking.  Configure the
optional setting if you want, the defaults are fine to get started.  
The settings are documented below.  
Make sure Global is set to where your web applications global.asa is 
if you have one!

 <Location /asp/>    
  SetHandler perl-script
  PerlHandler Apache::ASP
  PerlSetVar Global /tmp
 </Location>

NOTE: do not use this for the examples in ./site/eg.  To get the 
examples working, check out the Quick Start section of INSTALL

You may also use the <Files ~ (\.asp)> tag in the httpd.conf 
Apache configuration file or .htaccess, which allows a developer 
to mix other file types in the application, static or otherwise. 
This method is more natural for ASP coding, with mixed media
per directory.

=head2 Core

=item Global

Global is the nerve center of an ASP application, in which
the global.asa may reside, which defines the web application's 
event handlers.  

This directory is pushed onto @INC, you will be able 
to "use" and "require" files in this directory, so perl modules 
developed for this application may be dropped into this directory, 
for easy use.

Unless StateDir is configured, this directory must be some 
writeable directory by the web server.  $Session and $Application 
object state files will be stored in this directory.  If StateDir
is configured, then ignore this paragraph, as it overrides the 
Global directory for this purpose.

Includes, specified with <!--#include file=somefile.inc--> 
or $Response->Include() syntax, may also be in this directory, 
please see section on includes for more information.

  PerlSetVar Global /tmp

=item GlobalPackage

Perl package namespace that all scripts, includes, & global.asa
events are compiled into.  By default, GlobalPackage is some
obscure name that is uniquely generated from the file path of 
the Global directory, and global.asa file.  The use of explicitly
naming the GlobalPackage is to allow scripts access to globals
and subs defined in a perl module that is included with commands like:

  in perl script: use Some::Package;
  in apache conf: PerlModule Some::Package

  PerlSetVar GlobalPackage Some::Package

=item UniquePackages

default 0.  Set to 1 to emulate pre-v.10 ASP script compilation 
behavior, which compiles each script into its own perl package.

Before v.10, ASP scripts were compiled into their own perl package
namespace.  This allowed ASP scripts in the same ASP application
to defined subroutines of the same name without a problem.  

As of v.10, ASP scripts in a web application are compiled into the 
*same* perl package by default, so these scripts, their includes, and the 
global.asa events all share common globals & subroutines defined by each other.
The problem for some developers was that they would at times define a 
subroutine of the same name in 2+ scripts, and one subroutine definition would
redefine the other one because of the namespace collision.

  PerlSetVar UniquePackages 0

=item DynamicIncludes

default 0.  SSI file includes are normally inlined in the calling 
script, and the text gets compiled with the script as a whole. 
With this option set to TRUE, file includes are compiled as a
separate subroutine and called when the script is run.  
The advantage of having this turned on is that the code compiled
from the include can be shared between scripts, which keeps the 
script sizes smaller in memory, and keeps compile times down.

  PerlSetVar DynamicIncludes 0

=item IncludesDir

no defaults.  If set, this directory will also be used to look
for includes when compiling scripts.  By default the directory 
the script is in, and the Global directory are checked for includes.  

This extension was added so that includes could be easily shared
between ASP applications, whereas placing includes in the Global
directory only allows sharing between scripts in an application.

  PerlSetVar IncludesDir .

=head2 State Management

=item NoState

default 0, if true, neither the $Application nor $Session objects will
be created.  Use this for a performance increase.  Please note that 
this setting takes precedence over the AllowSessionState and
AllowApplicationState settings.

  PerlSetVar NoState 0

=item AllowSessionState

Set to 0 for no session tracking, 1 by default
If Session tracking is turned off, performance improves,
but the $Session object is inaccessible.

  PerlSetVar AllowSessionState 1    

Note that if you want to dissallow session creation
for certain non web browser user agents, like search engine
spiders, you can use an init handler like:

  PerlInitHandler "sub { $_[0]->dir_config('AllowSessionState', 0) }"

=item AllowApplicationState

Default 1.  If you want to leave $Application undefined, then set this
to 0, for a performance increase of around 2-3%.  Allowing use of 
$Application is less expensive than $Session, as there is more
work for the StateManager associated with $Session garbage collection
so this parameter should be only used for extreme tuning.

  PerlSetVar AllowApplicationState 1

=item StateDir

default $Global/.state.  State files for ASP application go to 
this directory.  Where the state files go is the most important
determinant in what makes a unique ASP application.  Different
configs pointing to the same StateDir are part of the same
ASP application.

The default has not changed since implementing this config directive.
The reason for this config option is to allow operating systems with caching
file systems like Solaris to specify a state directory separately
from the Global directory, which contains more permanent files.
This way one may point StateDir to /tmp/myaspapp, and make one's ASP
application scream with speed.

  PerlSetVar StateDir ./.state

=item StateManager

default 10, this number specifies the numbers of times per SessionTimeout
that timed out sessions are garbage collected.  The bigger the number,
the slower your system, but the more precise Session_OnEnd's will be 
run from global.asa, which occur when a timed out session is cleaned up,
and the better able to withstand Session guessing hacking attempts.
The lower the number, the faster a normal system will run.  

The defaults of 20 minutes for SessionTimeout and 10 times for 
StateManager, has dead Sessions being cleaned up every 2 minutes.

  PerlSetVar StateManager 10

=item StateDB

default SDBM_File, this is the internal database used for state
objects like $Application and $Session.  Because an %sdbm_file hash 
has a limit on the size of a record / key value pair, usually 1024 bytes,
you may want to use another tied database like DB_File.  

With lightweight $Session and $Application use, you can get 
away with SDBM_File, but if you load it up with complex data like
  $Session{key} = { # very large complex object }
you might max out the 1024 limit.

Currently StateDB can only be: SDBM_File, DB_File
Please let me know if you would like to add any more to this list.

As of version .18, you may change this setting in a live production
environment, and new state databases created will be of this format.
With a prior version if you switch to a new StateDB, you would want to 
delete the old StateDir, as there will likely be incompatibilities between
the different database formats, including the way garbage collection
is handled.

  PerlSetVar StateDB SDBM_File

=item StateCache

Default 0, set to 1 for lock files that are acquired for $Application 
and an internal database used for session management to be cached
and held open between requests, for up to a 10% performance
gain.  Per ASP application this is will keep up to 2 extra
file handles open per httpd process, one for the internal
database, and one for $Application.

The only problem with this caching is that you can only
delete the StateDir if you have first shutdown the web server,
as the lock files will not be recreated between requests.
Not that you should be deleting your StateDir anyway, but
if you are, there is more to worry about. 

  PerlSetVar StateCache 0

=item StateSerializer

default Data::Dumper, you may set this to Storable for 
faster serialization and storage of data into state objects.
This is particularly useful when storing large objects in
$Session and $Application, as the Storable.pm module has a faster
implementation of freezing and thawing data from and to
perl structures.  Note that if you are storing this much
data in your state databases, you may want to use 
DB_File since it does not have the default 1024 byte limit 
that SDBM_File has on key/value lengths.

This configuration setting may be changed in production
as the state database's serializer type is stored
in the internal state manager which will always use 
Data::Dumper & SDBM_File to store data.

  PerlSetVar StateSerializer Data::Dumper

=head2 Sessions

=item CookiePath

URL root that client responds to by sending the session cookie.
If your asp application falls under the server url "/asp", 
then you would set this variable to /asp.  This then allows
you to run different applications on the same server, with
different user sessions for each application.

  PerlSetVar CookiePath /   

=item SessionTimeout

Default 20 minutes, when a user's session has been inactive for this
period of time, the Session_OnEnd event is run, if defined, for 
that session, and the contents of that session are destroyed.

  PerlSetVar SessionTimeout 20 

=item SecureSession

default 0.  Sets the secure tag for the session cookie, so that the cookie
will only be transmitted by the browser under https transmissions.

  PerlSetVar SecureSession 1

=item ParanoidSession

default 0.  When true, stores the user-agent header of the browser 
that creates the session and validates this against the session cookie presented.
If this check fails, the session is killed, with the rationale that 
there is a hacking attempt underway.

This config option was implemented to be a smooth upgrade, as
you can turn it off and on, without disrupting current sessions.  
Sessions must be created with this turned on for the security to take effect.

This config option is to help prevent a brute force cookie search from 
being successful. The number of possible cookies is huge, 2^128, thus making such
a hacking attempt VERY unlikely.  However, on the off chance that such
an attack is successful, the hacker must also present identical
browser headers to authenticate the session, or the session will be
destroyed.  Thus the User-Agent acts as a backup to the real session id.
The IP address of the browser cannot be used, since because of proxies,
IP addresses may change between requests during a session.

There are a few browsers that will not present a User-Agent header.
These browsers are considered to be browsers of type "Unknown", and 
this method works the same way for them.

Most people agree that this level of security is unnecessary, thus
it is titled paranoid :)

  PerlSetVar ParanoidSession 0

=item SessionSerialize

default 0, if true, locks $Session for duration of script, which
serializes requests to the $Session object.  Only one script at
a time may run, per user $Session, with sessions allowed.

Serialized requests to the session object is the Microsoft ASP way, 
but is dangerous in a production environment, where there is risk
of long-running or run-away processes.  If these things happen,
a session may be locked for an indefinite period of time.  A user
STOP button should safely quit the session however.

  PerlSetVar SessionSerialize 0

=head2 Cookieless Sessions

=item SessionQueryParse

default 0, if true, will automatically parse the $Session
session id into the query string of each local URL found in the 
$Response buffer.  For this setting to work therefore, 
buffering must be enabled.  This parsing will only occur
when a session cookie has not been sent by a browser, so the 
first script of a session enabled site, and scripts viewed by 
web browsers that have cookies disabled will trigger this behavior.

Although this runtime parsing method is computationally 
expensive, this cost should be amortized across most users
that will not need this URL parsing.  This is a lazy programmer's
dream.  For something more efficient, look at the SessionQuery
setting.  For more information about this solution, please 
read the SESSIONS section.

  PerlSetVar SessionQueryParse 0

=item SessionQueryParseMatch

default 0, set to a regexp pattern that matches all URLs that you 
want to have SessionQueryParse parse in session ids.  By default
SessionQueryParse only modifies local URLs, but if you name
your URLs of your site with absolute URLs like http://localhost
then you will need to use this setting.  So to match 
http://localhost URLs, you might set this pattern to 
^http://localhost.  Note that by setting this config,
you are also setting SessionQueryParse.

  PerlSetVar SessionQueryParseMatch ^https?://localhost

=item SessionQuery

default 0, if set, the session id will be initialized from
the $Request->QueryString if not first found as a cookie.
You can use this setting coupled with the 

  $Server->URL($url, \%params) 

API extension to generate local URLs with session ids in their
query strings, for efficient cookieless session support.
Note that if a browser has cookies disabled, every URL
to any page that needs access to $Session will need to
be created by this method, unless you are using SessionQueryParse
which will do this for you automatically.

  PerlSetVar SessionQuery 0

=item SessionQueryMatch

default 0, set to a regexp pattern that will match
URLs for $Server->URL() to add a session id to.  SessionQuery
normally allows $Server->URL() to add session ids just to 
local URLs, so if you use absolute URL references like 
http://localhost/ for your web site, then just like 
with SessionQueryParseMatch, you might set this pattern
to ^http://localhost

If this is set, then you don't need to set SessionQuery,
as it will be set automatically.

  PerlSetVar SessionQueryMatch ^http://localhost

=head2 Developer Environment

=item UseStrict

default 0, if set to 1, will compile all scripts, global.asa
and includes with "use strict;" inserted at the head of 
the file, saving you from the painful process of strictifying
code that was not strict to begin with.

Because of how essential "use strict" programming is in
a mod_perl environment, this default might be set to 1 
one day, but this will be up for discussion before that
decision is made.

Note too that errors triggered by "use strict" are
now captured as part of the normal Apache::ASP error 
handling when this configuration is set, otherwise
"use strict" errors will not be handled properly, so
using UseStrict is better than your own "use strict"
statements.

PerlSetVar UseStrict 1

=item Debug

1 for server log debugging, 2 for extra client html output
Use 1 for production debugging, use 2 for development.
Turn off if you are not debugging.

  PerlSetVar Debug 2	

=item DebugBufferLength

Default 100, set this to the number of bytes of the 
buffered output's tail you want to see when an error occurs
and Debug 2 or MailErrorsTo is set, and when 
BufferingOn is enabled.  

With buffering the script output will not naturally show 
up when the script errors, as it has been buffered by the 
$Response object.  It helps to see where in the script
output an error halted the script, so the last bytes of 
the buffered output are included with the rest of 
the debugging information.  

For a demo of this functionality, try the 
./site/eg/syntax_error.htm script, and turn buffering on.

=item PodComments

default 1.  With pod comments turned on, perl pod style comments
and documentation are parsed out of scripts at compile time.
This make for great documentation and a nice debugging tool,
and it lets you comment out perl code and html in blocks.  
Specifically text like this:

 =pod
 text or perl code here
 =cut 

will get ripped out of the script before compiling.  The =pod and =cut 
perl directives must be at the beginning of the line, and must
be followed by the end of the line.

  PerlSetVar PodComments 1

=head2 XML / XSLT

=item XMLSubsMatch

default not defined, set to some regexp pattern
that will match all XML and HTML tags that you want
to have perl subroutines handle.  The is Apache::ASP's
custom tag technology, and can be used to create
powerful extensions to your XML and HTML rendering.

Please see XML/XSLT section for instructions on its use.

  PerlSetVar XMLSubsMatch ^my:

=item XSLT

default not defined, if set to a file, ASP scripts will
be regarded as XML output and transformed with the given
XSL file with XML::XSLT.  This XSL file will also be
executed as an ASP script first, and its output will be
the XSL data used for the transformation.  This XSL file
will be executed as a dynamic include, so may be located
in the current directory, Global, or IncludesDir.

Please see the XML/XSLT section for an explanation of its
use.

  PerlSetVar XSLT template.xsl

=item XSLTMatch

default .*, if XSLT is set by default all ASP scripts 
will be XSL transformed by the specified XSL template.
This regexp setting will tell XSLT which file names to 
match with doing XSL transformations, so that regular
HTML ASP scripts and XML ASP scripts can be configured
with the same configuration block.  Please see
./site/eg/.htaccess for an example of its use.

  PerlSetVar XSLTMatch \.xml$

=item XSLTCacheSize

default 0, if set greater than 0, will cache that many 
XML and XSL parsed objects and their transformations'
output.  XML::XSLT transformations are computationally
expensive, requiring first XML DOM objects be created
from the XML & XSL outputs, and then the final XSLT
rendering is non-trivial too, so every effort is made
to cache various steps in the process for enormous 
speed benefits if the same XML / XSL combination is 
being hit on the same web server process.

Efforts will be made in the future to provide a mechanism
for pre-caching these computations at server startup prefork 
so that they may be shared with the child Apache httpds.

This setting requires that Tie::Cache be first installed.

  PerlSetVar XSLTCacheSize 100

=head2 Miscellaneous

=item BufferingOn

default 1, if true, buffers output through the response object.
$Response object will only send results to client browser if
a $Response->Flush() is called, or if the asp script ends.  Lots of 
output will need to be flushed incrementally.

If false, 0, the output is immediately written to the client,
CGI style.  There will be a performance hit server side if output
is flushed automatically to the client, but is probably small.

I would leave this on, since error handling is poor, if your asp 
script errors after sending only some of the output.

  PerlSetVar BufferingOn 1

=item StatINC

default 0, if true, reloads perl libraries that have changed
on disk automatically for ASP scripts.  If false, the www server
must be restarted for library changes to take effect.

A known bug is that any functions that are exported, e.g. confess 
Carp qw(confess), will not be refreshed by StatINC.  To refresh
these, you must restart the www server.  

This setting should be used in development only because it is so slow.
For a production version of StatINC, see StatINCMatch.

  PerlSetVar StatINC 1

=item StatINCMatch

default undef, if defined, it will be used as a regular expression
to reload modules that match as in StatINC.  This is useful because
StatINC has a very high performance penalty in production, so if
you can narrow the modules that are checked for reloading each
script execution to a handful, you will only suffer a mild performance 
penalty.

The StatINCMatch setting should be a regular expression like: Struct|LWP
which would match on reloading Class/Struct.pm, and all the LWP/.*
libraries.

If you define StatINCMatch, you do not need to define StatINC.

  PerlSetVar StatINCMatch .*

=item StatScripts

default 1, if set to 0, changed scripts, global.asa, and includes
will not be reloaded.  Coupled with Apache mod_perl startup and restart
handlers executing Apache::ASP->Loader() for your application
this allows your application to be frozen, and only reloaded on the 
next server restart or stop/start.

There are a few advantages for not reloading scripts and modules
in production.  First there is a slight performance improvement
by not having to stat() the script, its includes and the global.asa
every request.  

From an application deployment standpoint, you
also gain the ability to deploy your application as a 
snapshot taken when the server starts and restarts.
This provides you with the reassurance that during a
production server update from development sources, you 
do not have to worry with sources being used for the 
wrong libraries and such, while they are all being 
copied over.

Finally, though you really should not do this, you can
work on a live production application, with a test server
reloading changes, but your production server does see
the changes until you restart or stop/start it.  This 
saves your public from syntax errors while you are just
doing a quick bug fix.

  PerlSetVar StatScripts 1

=item SoftRedirect

default 0, if true, a $Response->Redirect() does not end the 
script.  Normally, when a Redirect() is called, the script
is ended automatically.  SoftRedirect 1, is a standard
way of doing redirects, allowing for html output after the 
redirect is specified.

  PerlSetVar SoftRedirect 0

=item Filter

On/Off, default Off.  With filtering enabled, you can take advantage of 
full server side includes (SSI), implemented through Apache::SSI.  
SSI is implemented through this mechanism by using Apache::Filter.  
A sample configuration for full SSI with filtering is in the 
./site/eg/.htaccess file, with a relevant example script ./site/eg/ssi_filter.ssi.

You may only use this option with modperl v1.16 or greater installed
and PERL_STACKED_HANDLERS enabled.  Filtering may be used in 
conjunction with other handlers that are also "filter aware".
If in doubt, try building your mod_perl with 

  perl Makefile.PL EVERYTHING=1

With filtering through Apache::SSI, you should expect near a
a 20% performance decrease.

  PerlSetVar Filter Off

=item CgiHeaders

default 0.  When true, script output that looks like HTTP / CGI
headers, will be added to the HTTP headers of the request.
So you could add:
  Set-Cookie: test=message
  
  <html>...
to the top of your script, and all the headers preceding a newline
will be added as if with a call to $Response->AddHeader().  This
functionality is here for compatibility with raw cgi scripts,
and those used to this kind of coding.

When set to 0, CgiHeaders style headers will not be parsed from the 
script response.

  PerlSetVar CgiHeaders 0

=item Clean

default 0, may be set between 1 and 9.  This setting determine how much
text/html output should be compressed.  A setting of 1 strips mostly
white space saving usually 10% in output size, at a performance cost
of less than 5%.  A setting of 9 goes much further saving anywhere
25% to 50% typically, but with a performance hit of 50%.

This config option is implemented via HTML::Clean.  Per script
configuration of this setting is available via the $Response->{Clean}
property, which may also be set between 0 and 9.

  PerlSetVar Clean 0

=item CompressGzip

default 0, if true will gzip compress HTML output on the
fly if Compress::Zlib is installed, and the client browser
supports it.  Depending on the HTML being compressed, 
the client may see a 50% to 90% reduction in HTML output.
I have seen 40K of HTML squeezed down to just under 6K.
This will come at a 5%-20% hit to CPU usage per request
compressed.

Note there are some cases when a browser says it will accept
gzip encoding, but then not render it correctly.  This
behavior has been seen with IE5 when set to use a proxy but 
not using a proxy, and the URL does not end with a .html or .htm.
No work around has yet been found for this case so use at your 
own risk.

  PerlSetVar CompressGzip 1

=item TimeHiRes

default 0, if set and Time::HiRes is installed, will do 
sub second timing of the time it takes Apache::ASP to process
a request.  This will not include the time spent in the 
session manager, nor modperl or Apache, and is only a 
rough approximation at best.

If Debug is set also, you will get a comment in your
HTML output that indicates the time it took to process
that script.

If system debugging is set with Debug -1 or -2, you will
also get this time in the Apache error log with the 
other system messages.

=head2 Mail Administration

Apache::ASP has some powerful administrative email
extensions that let you sleep at night, knowing full well
that if an error occurs at the web site, you will know
about it immediately.  With these features already enabled,
it was also easy to provide the $Server->Mail(\%mail) API 
extension which you can read up about in the OBJECTS section.

=item MailHost

The mail host is the smtp server that the below Mail* config directives
will use when sending their emails.  By default Net::SMTP uses
smtp mail hosts configured in Net::Config, which is set up at
install time, but this setting can be used to override this config.

The mail hosts specified in the Net::Config file will be used as
backup smtp servers to the MailHost specified here, should this
primary server not be working.

  PerlSetVar MailHost smtp.yourdomain.com.foobar

=item MailFrom

Default NONE, set this to specify the default mail address placed 
in the From: mail header for the $Server->Mail() API extension, 
as well as MailErrorsTo and MailAlertTo.

  PerlSetVar MailFrom youremail@yourdomain.com.foobar

=item MailErrorsTo

No default, if set, ASP server errors, error code 500, that result
while compiling or running scripts under Apache::ASP will automatically
be emailed to the email address set for this config.  This allows
an administrator to have a rapid response to user generated server
errors resulting from bugs in production ASP scripts.  Other errors, such 
as 404 not found will be handled by Apache directly.

An easy way to see this config in action is to have an ASP script which calls
a die(), which generates an internal ASP 500 server error.

The Debug config of value 2 and this setting are mutually exclusive,
as Debug 2 is a development setting where errors are displayed in the browser,
and MailErrorsTo is a production setting so that errors are silently logged
and sent via email to the web admin.

  PerlSetVar MailErrorsTo youremail@yourdomain.com

=item MailAlertTo

The address configured will have an email sent on any ASP server error 500,
and the message will be short enough to fit on a text based pager.  This
config setting would be used to give an administrator a heads up that a www
server error occurred, as opposed to MailErrorsTo would be used for debugging
that server error.

This config does not work when Debug 2 is set, as it is a setting for
use in production only, where Debug 2 is for development use.

  PerlSetVar MailAlertTo youremail@yourdomain.com

=item MailAlertPeriod

Default 20 minutes, this config specifies the time in minutes over 
which there may be only one alert email generated by MailAlertTo.
The purpose of MailAlertTo is to give the admin a heads up that there
is an error at the www server.  MailErrorsTo is for to aid in speedy 
debugging of the incident.

  PerlSetVar MailAlertPeriod 20

=head2 File Uploads

=item FileUploadMax

default 0, if set will limit file uploads to this
size in bytes.  This is currently implemented by 
setting $CGI::POST_MAX before handling the file
upload.  Prior to this, a developer would have to
hardcode a value for $CGI::POST_MAX to get this 
to work.

  PerlSetVar 100000

=item FileUploadTemp

default 0, if set will leave a temp file on disk during the request, 
which may be helpful for processing by other programs, but is also
a security risk in that other users on the operating system could 
potentially read this file while the script is running. 

The path to the temp file will be available at
$Request->{FileUpload}{$form_field}{TempFile}.
The regular use of file uploads remains the same
with the <$filehandle> to the upload at 
$Request->{Form}{$form_field}.  Please see the CGI section
for more information on file uploads, and the $Request
section in OBJECTS.

  PerlSetVar FileUploadTemp 0

=head1 SYNTAX

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

=head1 EVENTS

The ASP platform allows developers to create Web Applications.
In fulfillment of real software requirements, ASP allows 
event-triggered actions to be taken, which are defined in
a global.asa file.  The global.asa file resides in the 
Global directory, defined as a config option , and may
define the following actions:

	Action			Event
	------			------
        Script_OnStart *	Beginning of Script execution
        Script_OnEnd *		End of Script execution
        Script_OnFlush *	Before $Response being flushed to client.
	Application_OnStart	Beginning of Application
	Application_OnEnd	End of Application
	Session_OnStart		Beginning of user Session.
	Session_OnEnd		End of user Session.

  * These are API extensions that are not portable, but were
    added because they are incredibly useful

These actions must be defined in the $Global/global.asa file
as subroutines, for example:

  sub Session_OnStart {
      $Application->{$Session->SessionID()} = started;
  }

Sessions are easy to understand.  When visiting a page in a
web application, each user has one unique $Session.  This 
session expires, after which the user will have a new
$Session upon revisiting.

A web application starts when the user visits a page in that
application, and has a new $Session created.  Right before
the first $Session is created, the $Application is created.
When the last user $Session expires, that $Application 
expires also.

=head2 Script_OnStart & Script_OnEnd

The script events are used to run any code for all scripts
in an application defined by a global.asa.  Often, you would
like to run the same code for every script, which you would
otherwise have to add by hand, or add with a file include,
but with these events, just add your code to the global.asa,
and it will be run.  

There is one caveat.  Code in Script_OnEnd is not guaranteed 
to be run when the user hits a STOP button, since the program
execution ends immediately at this event.  To always run critical
code, use the API extension:

	$Server->RegisterCleanup()

=head2 Session_OnStart

Triggered by the beginning of a user's session, Session_OnStart
gets run before the user's executing script, and if the same
session recently timed out, after the session's triggered Session_OnEnd.

The Session_OnStart is particularly useful for caching database data,
and avoids having the caching handled by clumsy code inserted into
each script being executed.

=head2 Session_OnEnd

Triggered by a user session ending, Session_OnEnd can be useful
for cleaning up and analyzing user data accumulated during a session.

Sessions end when the session timeout expires, and the StateManager
performs session cleanup.  The timing of the Session_OnEnd does not
occur immediately after the session times out, but when the first 
script runs after the session expires, and the StateManager allows
for that session to be cleaned up.  

So on a busy site with default SessionTimeout (20 minutes) and 
StateManager (10 times) settings, the Session_OnEnd for a particular 
session should be run near 22 minutes past the last activity that Session saw.
A site infrequently visited will only have the Session_OnEnd run
when a subsequent visit occurs, and theoretically the last session
of an application ever run will never have its Session_OnEnd run.

Thus I would not put anything mission-critical in the Session_OnEnd,
just stuff that would be nice to run whenever it gets run.

=head2 Script_OnFlush

API extension. This event will be called prior to flushing
the $Response buffer to the web client.  At this time,
the $Response->{BinaryRef} buffer reference may be used to modify 
the buffered output at runtime to apply global changes to scripts 
output without having to modify all the scripts.

 sub Script_OnFlush {
   my $ref = $Response->{BinaryRef};
   $$ref =~ s/\s+/ /sg; # to strip extra white space
 }

Check out the ./site/eg/global.asa for an example of its use.

=head2 Application_OnStart

This event marks the beginning of an ASP application, and 
is run just before the Session_OnStart of the first Session
of an application.  This event is useful to load up
$Application with data that will be used in all user sessions.

=head2 Application_OnEnd

The end of the application is marked by this event, which
is run after the last user session has timed out for a 
given ASP application.  

=head1 OBJECTS

The beauty of the ASP Object Model is that it takes the
burden of CGI and Session Management off the developer, 
and puts them in objects accessible from any
ASP script & include.  For the perl programmer, treat these objects
as globals accessible from anywhere in your ASP application.

  Currently the Apache::ASP object model supports the following:
  
    Object	 -	Function
    ------		--------
    $Session	 -	user session state
    $Response	 -	output to browser
    $Request	 -	input from browser
    $Application -	application state
    $Server	 -	general support methods

These objects, and their methods are further defined in the 
following sections.

=head2 $Session Object

The $Session object keeps track of user and web client state, in
a persistent manner, making it relatively easy to develop web 
applications.  The $Session state is stored across HTTP connections,
in database files in the Global or StateDir directories, and will 
persist across web server restarts. 

The user session is referenced by a 128 bit / 32 byte MD5 hex hashed cookie, 
and can be considered secure from session id guessing, or session hijacking.
When a hacker fails to guess a session, the system times out for a
second, and with 2**128 (3.4e38) keys to guess, a hacker will not be 
guessing an id any time soon.  

If an incoming cookie matches a timed out or non-existent session,
a new session is created with the incoming id.  If the id matches a
currently active session, the session is tied to it and returned.
This is also similar to the Microsoft ASP implementation.

The $Session reference is a hash ref, and can be used as such to 
store data as in: 

    $Session->{count}++;	# increment count by one
    %{$Session} = ();	# clear $Session data

The $Session object state is implemented through MLDBM,
and a user should be aware of the limitations of MLDBM.  
Basically, you can read complex structures, but not write 
them, directly:

  $data = $Session->{complex}{data};     # Read ok.
  $Session->{complex}{data} = $data;     # Write NOT ok.
  $Session->{complex} = {data => $data}; # Write ok, all at once.

Please see MLDBM for more information on this topic.
$Session can also be used for the following methods and properties:

=over

=item $Session->{CodePage}

Not implemented.  May never be until someone needs it.

=item $Session->{LCID}

Not implemented.  May never be until someone needs it.

=item $Session->{SessionID}

SessionID property, returns the id for the current session,
which is exchanged between the client and the server as a cookie.

=item $Session->{Timeout} [= $minutes]

Timeout property, if minutes is being assigned, sets this 
default timeout for the user session, else returns 
the current session timeout.  

If a user session is inactive for the full
timeout, the session is destroyed by the system.
No one can access the session after it times out, and the system
garbage collects it eventually.

=item $Session->Abandon()

The abandon method times out the session immediately.  All Session
data is cleared in the process, just as when any session times out.

=item $Session->Lock()  

API extension. If you are about to use $Session for many consecutive 
reads or writes, you can improve performance by explicitly locking 
$Session, and then unlocking, like:

  $Session->Lock();
  $Session->{count}++;
  $Session->{count}++;
  $Session->{count}++;
  $Session->UnLock();  

This sequence causes $Session to be locked and unlocked only
1 time, instead of the 6 times that it would be locked otherwise,
2 for each increment with one to read and one to write.

Because of flushing issues with SDBM_File and DB_File databases,
each lock actually ties fresh to the database, so the performance
savings here can be considerable.  

Note that if you have SessionSerialize set, $Session is
already locked for each script invocation automatically, as if
you had called $Session->Lock() in Script_OnStart.  Thus you 
do not need to worry about $Session locking for performance.
Please read the section on SessionSerialize for more info.

=item $Session->UnLock()

API Extension. Unlocks the $Session explicitly.  If you do not call this,
$Session will be unlocked automatically at the end of the 
script.

=back

=head2 $Response Object

This object manages the output from the ASP Application and the 
client web browser.  It does not store state information like the 
$Session object but does have a wide array of methods to call.

=over

=item $Response->{BinaryRef}

API extension. This is a perl reference to the buffered output of 
the $Response object, and can be used in the Script_OnFlush
global.asa event to modify the buffered output at runtime
to apply global changes to scripts output without having to 
modify all the scripts.  These changes take place before 
content is flushed to the client web browser.

 sub Script_OnFlush {
   my $ref = $Response->{BinaryRef};
   $$ref =~ s/\s+/ /sg; # to strip extra white space
 }

Check out the ./site/eg/global.asa for an example of its use.

=item $Response->{Buffer}

Default 1, when TRUE sends output from script to client only at
the end of processing the script.  When 0, response is not buffered,
and client is sent output as output is generated by the script.

=item $Response->{CacheControl}

Default "private", when set to public allows proxy servers to 
cache the content.  This setting controls the value set
in the HTTP header Cache-Control

=item $Response->{Charset}

This member when set appends itself to the value of the Content-Length
HTTP header.  If $Response->{Charset} = 'ISO-LATIN-1' is set, the 
corresponding header would look like:

  Content-Type: text/html; charset=ISO-LATIN-1

=item $Response->{Clean} = 0-9;

API extension. Set the Clean level, default 0, on a per script basis.  
Clean of 1-9 compresses text/html output.  Please see
the Clean config option for more information.

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

 "Wed, 09 Feb 1994 22:23:32 GMT"     -- HTTP format
 "Tuesday, 08-Feb-94 14:15:29 GMT"   -- old rfc850 HTTP format

 "08-Feb-94"       -- old rfc850 HTTP format    
 "09 Feb 1994"     -- proposed new HTTP format  

 "Feb  3  1994"    -- Unix 'ls -l' format
 "Feb  3 17:03"    -- Unix 'ls -l' format

=item $Response->{IsClientConnected}

Not implemented, but returns 1 currently for portability.  This is 
value is not yet relevant, and may not be until apache 1.3.6, which will 
be tested shortly.  Apache versions less than 1.3.6 abort the perl code 
immediately upon the client dropping the connection.

=item $Response->{PICS}

If this property has been set, a PICS-Label HTTP header will be
sent with its value.  For those that do not know, PICS is a header
that is useful in rating the internet.  It stands for 
Platform for Internet Content Selection, and you can find more
info about it at: http://www.w3.org

=item $Response->{Status} = $status

Sets the status code returned by the server.  Can be used to
set messages like 500, internal server error

=item $Response->AddHeader($name, $value)

Adds a custom header to a web page.  Headers are sent only before any
text from the main page is sent, so if you want to set a header
after some text on a page, you must turn BufferingOn.

=item $Response->AppendToLog($message)

Adds $message to the server log.  Useful for debugging.

=item $Response->BinaryWrite($data)

Writes binary data to the client.  The only
difference from $Response->Write() is that $Response->Flush()
is called internally first, so the data cannot be parsed 
as an html header.  Flushing flushes the header if has not
already been written.

If you have set the $Response->{ContentType}
to something other than text/html, cgi header parsing (see CGI
notes), will be automatically be turned off, so you will not
necessarily need to use BinaryWrite for writing binary data.

For an example of BinaryWrite, see the binary_write.htm example 
in ./site/eg/binary_write.htm

Please note that if you are on Win32, you will need to 
call binmode on a file handle before reading, if 
its data is binary.

=item $Response->Clear()

Erases buffered ASP output.

=item $Response->Cookies($name, [$key,] $value)

Sets the key or attribute of cookie with name $name to the value $value.
If $key is not defined, the Value of the cookie is set.
ASP CookiePath is assumed to be / in these examples.

 $Response->Cookies('name', 'value'); 
  --> Set-Cookie: name=value; path=/

 $Response->Cookies("Test", "data1", "test value");     
 $Response->Cookies("Test", "data2", "more test");      
 $Response->Cookies(
	"Test", "Expires", 
	&HTTP::Date::time2str(time+86400)
	); 
 $Response->Cookies("Test", "Secure", 1);               
 $Response->Cookies("Test", "Path", "/");
 $Response->Cookies("Test", "Domain", "host.com");
  -->	Set-Cookie:Test=data1=test%20value&data2=more%20test;	\
 		expires=Fri, 23 Apr 1999 07:19:52 GMT;		\
 		path=/; domain=host.com; secure

The latter use of $key in the cookies not only sets cookie attributes
such as Expires, but also treats the cookie as a hash of key value pairs
which can later be accesses by

 $Request->Cookies('Test', 'data1');
 $Request->Cookies('Test', 'data2');

Because this is perl, you can (NOT PORTABLE) reference the cookies
directly through hash notation.  The same 5 commands above could be compressed to:

 $Response->{Cookies}{Test} = 
	{ 
		Secure	=> 1, 
		Value	=>	
			{
				data1 => 'test value', 
				data2 => 'more test'
			},
		Expires	=> 86400, # not portable, see above
		Domain	=> 'host.com',
		Path    => '/'
	};

and the first command would be:

 # you don't need to use hash notation when you are only setting 
 # a simple value
 $Response->{Cookies}{'Test Name'} = 'Test Value'; 

I prefer the hash notation for cookies, as this looks nice, and is 
quite perlish.  It is here to stay.  The Cookie() routine is 
very complex and does its best to allow access to the 
underlying hash structure of the data.  This is the best emulation 
I could write trying to match the Collections functionality of 
cookies in IIS ASP.

For more information on Cookies, please go to the source at
http://home.netscape.com/newsref/std/cookie_spec.html

=item $Response->Debug(@args)

API Extension. If the Debug config option is set greater than 0, 
this routine will write @args out to server error log.  refs in @args 
will be expanded one level deep, so data in simple data structures
like one-level hash refs and array refs will be displayed.  CODE
refs like

 $Response->Debug(sub { "some value" });

will be executed and their output added to the debug output.
This extension allows the user to tie directly into the
debugging capabilities of this module.

While developing an app on a production server, it is often 
useful to have a separate error log for the application
to catch debugging output separately.  One way of implementing 
this is to use the Apache ErrorLog configuration directive to 
create a separate error log for a virtual host. 

If you want further debugging support, like stack traces
in your code, consider doing things like:

 $Response->Debug( sub { Carp::longmess('debug trace') };
 $SIG{__WARN__} = \&Carp::cluck; # then warn() will stack trace

The only way at present to see exactly where in your script
an error occurred is to set the Debug config directive to 2,
and match the error line number to perl script generated
from your ASP script.  

However, as of version 0.10, the perl script generated from the 
asp script should match almost exactly line by line, except in 
cases of inlined includes, which add to the text of the original script, 
pod comments which are entirely yanked out, and <% # comment %> style
comments which have a \n added to them so they still work.

If you would like to see the HTML preceding an error 
while developing, consider setting the BufferingOn 
config directive to 0.

=item $Response->End()

Sends result to client, and immediately exits script.
Automatically called at end of script, if not already called.

=item $Response->ErrorDocument($code, $uri)

API extension that allows for the modification the Apache
ErrorDocument at runtime.  $uri may be a on site document,
off site URL, or string containing the error message.  

This extension is useful if you want to have scripts
set error codes with $Response->{Status} like 401
for authentication failure, and to then control from
the script what the error message looks like.

For more information on the Apache ErrorDocument mechanism,
please see ErrorDocument in the CORE Apache settings,
and the Apache->custom_response() API, for which this method
is a wrapper.

=item $Response->Flush()

Sends buffered output to client and clears buffer.

=item $Response->Include($filename, @args)

This API extension calls the routine compiled from asp script
in $filename with the args @args.  This is a direct translation
of the SSI tag 

  <!--#include file=$filename args=@args-->

Please see the SSI section for more on SSI in general.

This API extension was created to allow greater modularization
of code by allowing includes to be called with runtime 
arguments.  Files included are compiled once, and the 
anonymous code ref from that compilation is cached, thus
including a file in this manner is just like calling a 
perl subroutine.

=item $Response->Redirect($url)

Sends the client a command to go to a different url $url.  
Script immediately ends.

=item $Response->Write($data)

Write output to the HTML page.  <%=$data%> syntax is shorthand for
a $Response->Write($data).  All final output to the client must at
some point go through this method.

=back

=head2 $Request Object

The request object manages the input from the client browser, like
posts, query strings, cookies, etc.  Normal return results are values
if an index is specified, or a collection / perl hash ref if no index 
is specified.  WARNING, the latter property is not supported in 
ActiveState PerlScript, so if you use the hashes returned by such
a technique, it will not be portable.

A normal use of this feature would be to iterate through the 
form variables in the form hash...

 $form = $Request->Form();
 for(keys %{$form}) {
	$Response->Write("$_: $form->{$_}<br>\n");
 }

Please see the ./site/eg/server_variables.htm asp file for this 
method in action.

Note that if a form POST or query string contains duplicate
values for a key, those values will be returned through
normal use of the $Request object:

  @values = $Request->Form('key');

but you can also access the internal storage, which is
an array reference like so:

  $array_ref = $Request->{Form}{'key'};
  @values = @{$array_ref};

Please read the PERLSCRIPT section for more information 
on how things like $Request->QueryString() & $Request->Form()
behave as collections.

=over

=item $Request->{TotalBytes}

The amount of data sent by the client in the body of the 
request, usually the length of the form data.  This is
the same value as $Request->ServerVariables('CONTENT_LENGTH')

=item $Request->BinaryRead($length)

Returns a scalar whose contents are the first $length bytes
of the form data, or body, sent by the client request.
This data is the raw data sent by the client, without any
parsing done on it by Apache::ASP.

=item $Request->ClientCertificate()

Not implemented.

=item $Request->Cookies($name [,$key])

Returns the value of the Cookie with name $name.  If a $key is
specified, then a lookup will be done on the cookie as if it were
a query string.  So, a cookie set by:

 Set-Cookie: test=data1=1&data2=2

would have a value of 2 returned by $Request->Cookies('test','data2').

If no name is specified, a hash will be returned of cookie names 
as keys and cookie values as values.  If the cookie value is a query string, 
it will automatically be parsed, and the value will be a hash reference to 
these values.

When in doubt, try it out.  Remember that unless you set the Expires
attribute of a cookie with $Response->Cookies('cookie', 'Expires', $xyz),
the cookies that you set will only last until you close your browser, 
so you may find your self opening & closing your browser a lot when 
debugging cookies.

For more information on cookies in ASP, please read $Response->Cookies()

=item $Request->FileUpload($form_field, $key)

API extension.  The FileUpload interface to file upload data is
stabilized.  The internal representation of the file uploads
is a hash of hashes, one hash per file upload found in 
the $Request->Form() collection.  This collection of collections
may be queried through the normal interface like so:

  $Request->FileUpload('upload_file', 'ContentType');
  $Request->FileUpload('upload_file', 'FileHandle');
  $Request->FileUpload('upload_file', 'BrowserFile');
  $Request->FileUpload('upload_file', 'Mime-Header');
  $Request->FileUpload('upload_file', 'TempFile');

  * note that TempFile must be use with the UploadTempFile 
    configuration setting.

The above represents the old slow collection interface, 
but like all collections in Apache::ASP, you can reference
the internal hash representation more easily.

  my $fileup = $Request->{FileUpload}{upload_file};
  $fileup->{ContentType};
  $fileup->{BrowserFile};
  $fileup->{FileHandle};
  $fileup->{Mime-Header};
  $fileup->{TempFile};

=item $Request->Form($name)

Returns the value of the input of name $name used in a form
with POST method.  If $name is not specified, returns a ref to 
a hash of all the form data.  

File upload data will be loaded into $Request->Form('file_field'), 
where the value is the actual file name of the file uploaded, and 
the contents of the file can be found by reading from the file
name as a file handle as in:

 while(read($Request->Form('file_field_name'), $data, 1024)) {};

For more information, please see the CGI / File Upload section,
as file uploads are implemented via the CGI.pm module.  An
example can be found in the installation 
samples ./site/eg/file_upload.asp

=item $Request->QueryString($name)

Returns the value of the input of name $name used in a form
with GET method, or passed by appending a query string to the end of
a url as in http://localhost/?data=value.  
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
is locked, this guarantees that data being read and written to it 
will not suddenly change on you between the reads and the writes.

This and the $Session object both lock automatically upon
every read and every write to ensure data integrity.  This 
lock is useful for concurrent access control purposes.

Be careful to not be too liberal with this, as you can quickly 
create application bottlenecks with its improper use.

=item $Application->UnLock()

Unlocks the $Application object.  If already unlocked, does nothing.

=item $Application->GetSession($sess_id)

This NON-PORTABLE API extension returns a user $Session given
a session id.  This allows one to easily write a session manager if
session ids are stored in $Application during Session_OnStart, with 
full access to these sessions for administrative purposes.  

Be careful not to expose full session ids over the net, as they
could be used by a hacker to impersonate another user.  So when 
creating a session manager, for example, you could create
some other id to reference the SessionID internally, which 
would allow you to control the sessions.  This kind of application
would best be served under a secure web server.

The ./site/eg/global_asa_demo.asp script makes use of this routine 
to display all the data in current user sessions.

=item $Application->SessionCount()

This NON-PORTABLE method returns the current number of active sessions,
in the application.  This method is not implemented as part of the ASP
object model, but is implemented here because it is useful.  In particular,
when accessing databases with license requirements, one can monitor usage
effectively through accessing this value.

This is a new feature as of v.06, and if run on a site with previous 
versions of Apache::ASP, the count may take a while to synch up.  To ensure
a correct count, you must delete all the current state files associated
with an application, usually in the $Global/.state directory.

=back

=head2 $Server Object

The server object is that object that handles everything the other
objects do not.  The best part of the server object for Win32 users is 
the CreateObject method which allows developers to create instances of
ActiveX components, like the ADO component.

=over

=item $Server->{ScriptTimeout} = $seconds

Not implemented. May never be.  Please see the 
Apache Timeout configuration option, normally in httpd.conf.  

=item $Server->Config($setting)

API extension.  Allows a developer to read the CONFIG
settings, like Global, GlobalPackage, StateDir, etc.
Currently implemented as a wrapper around 

  Apache->dir_config($setting)

=item $Server->CreateObject($program_id)

Allows use of ActiveX objects on Win32.  This routine returns
a reference to an Win32::OLE object upon success, and nothing upon
failure.  It is through this mechanism that a developer can 
utilize ADO.  The equivalent syntax in VBScript is 

 Set object = Server.CreateObject(program_id)

For further information, try 'perldoc Win32::OLE' from your
favorite command line.

=item $Server->Execute($file, @args)

New method from ASP 3.0, this does the same thing as

  $Response->Include($file, @args)

and internally is just a wrapper for such.  Seems like we
had this important functionality before the IIS/ASP camp!

=item $Server->GetLastError()

Not implemented, will likely not ever be because this is dependent
on how IIS handles errors and is not relevant in Apache.

=item $Server->HTMLEncode($string)

Returns an HTML escapes version of $string. &, ", >, <, are each
escapes with their HTML equivalents.  Strings encoded in this nature
should be raw text displayed to an end user, as HTML tags become 
escaped with this method.                                 "

=item $Server->MapPath($url);

Given the url $url, absolute, or relative to the current executing script,
this method returns the equivalent filename that the server would 
translate the request to, regardless or whether the request would be valid.

Only a $url that is relative to the host is valid.  Urls like "." and 
"/" are fine arguments to MapPath, but http://localhost would not be.

To see this method call in action, check out the sample ./site/eg/server.htm
script.

=item $Server->Mail(\%mail, %smtp_args);

With the Net::SMTP and Net::Config modules installed, which are part of the 
perl libnet package, you may use this API extension to send email.  The 
\%mail hash reference that you pass in must have values for at least
the To, From, and Subject headers, and the Body of the mail message.

You could send an email like so:

 $Server->Mail({
		To => 'somebody@yourdomain.com.foobar',
		From => 'youremail@yourdomain.com.foobar',
		Subject => 'Subject of Email',
		Body => 
		 'Body of message. '.
		 'You might have a lot to say here!',
		Organization => 'Your Organization',
	       });

Any extra fields specified for the email will be interpreted
as headers for the email, so to send an HTML email, you 
could set 'Content-Type' => 'text/html' in the above example.

If you have MailFrom configured, this will be the default
for the From header in your email.  For more configuration
options like the MailHost setting, check out the CONFIG section.

The return value of this method call will be boolean for
success of the mail being sent.

If you would like to specially configure the Net::SMTP 
object used internally, you may set %smtp_args and they
will be passed on when that object is initialized.
"perldoc Net::SMTP" for more into on this topic.

=item $Server->Transfer($file)

New method from ASP 3.0.  Transfers control to another script.  
The Response buffer will not be cleared automatically, so if you 
want this to serve as a faster $Response->Redirect(), you will need to 
call $Response->Clear() before calling this method.  

This new script will take over current execution and 
the current script will not continue to be executed
afterwards.  It differs from Execute() because the 
original script will not pick up where it left off.

=item $Server->URLEncode($string)

Returns the URL-escaped version of the string $string. +'s are substituted in
for spaces and special characters are escaped to the ascii equivalents.
Strings encoded in this manner are safe to put in urls... they are especially
useful for encoding data used in a query string as in:

 $data = $Server->URLEncode("test data");
 $url = "http://localhost?data=$data";

 $url evaluates to http://localhost?data=test+data, and is a 
 valid URL for use in anchor <a> tags and redirects, etc.

=item $Server->RegisterCleanup($sub) 

 non-portable extension

Sets a subroutine reference to be executed after the script ends,
whether normally or abnormally, the latter occurring 
possibly by the user hitting the STOP button, or the web server
being killed.  This subroutine must be a code reference 
created like:

 $Server->RegisterCleanup(sub { $main::Session->{served}++; });
   or
 sub served { $main::Session->{served}++; }
 $Server->RegisterCleanup(\&served);

The reference to the subroutine passed in will be executed.
Though the subroutine will be executed in anonymous context, 
instead of the script, all objects will still be defined 
in main::*, that you would reference normally in your script.  
Output written to $main::Response will have no affect at 
this stage, as the request to the www client has already completed.

Check out the ./site/eg/register_cleanup.asp script for an example
of this routine in action.

=item $Server->URL($url, \%params) 

Will return a URL with %params serialized into a query 
string like:

  $url = $Server->URL('test.asp', { test => value });

which would give you a URL of test.asp?test=value

Used in conjunction with the SessionQuery* settings, the returned
URL will also have the session id inserted into the query string, 
making this a critical part of that method of implementing 
cookieless sessions.  For more information on that topic 
please read on the setting
in the CONFIG section, and the SESSIONS section too.

=back

=head1 SSI

SSI is great!  One of the main features of SSI is to include
other files in the script being requested.  In Apache::ASP, this
is implemented in a couple ways, the most crucial of which
is implemented in the file include.  Formatted as

 <!--#include file=filename.inc-->

,the .inc being merely a convention, text from the included 
file will be inserted directly into the script being executed
and the script will be compiled as a whole.  Whenever the 
script or any of its includes change, the script will be 
recompiled.

Includes go a great length to promote good decomposition
and code sharing in ASP scripts, but they are still 
fairly static.  As of version .09, includes may have dynamic
runtime execution, as subroutines compiled into the global.asa
namespace.  The first way to invoke includes dynamically is

 <!--#include file=filename.inc args=@args-->

If @args is specified, Apache::ASP knows to execute the 
include at runtime instead of inlining it directly into 
the compiled code of the script.  It does this by
compiling the script at runtime as a subroutine, and 
caching it for future invocations.  Then the compiled
subroutine is executed and has @args passed into its
as arguments.

This is still might be too static for some, as @args
is still hardcoded into the ASP script, so finally,
one may execute an include at runtime by utilizing
this API extension

   $Response->Include("filename.inc", @args);

which is a direct translation of the dynamic include above.

Although inline includes should be a little faster,
runtime dynamic includes represent great potential
savings in httpd memory, as includes are shared
between scripts keeping the size of each script
to a minimum.  This can often be significant saving
if much of the formatting occurs in an included 
header of a www page.

By default, all includes will be inlined unless
called with an args parameter.  However, if you
want all your includes to be compiled as subs and 
dynamically executed at runtime, turn the DynamicIncludes
config option on as documented above.

That is not all!  SSI is full featured.  One of the 
things missing above is the 

 <!--#include virtual=filename.cgi-->

tag.  This and many other SSI code extensions are available
by filtering Apache::ASP output through Apache::SSI via
the Apache::Filter and the Filter config options.  For
more information on how to wire Apache::ASP and Apache::SSI
together, please see the Filter config option documented
above.  Also please see Apache::SSI for further information
on the capabilities it offers.

=head1 EXAMPLES

Use with Apache.  Copy the ./site/eg directory from the ASP installation 
to your Apache document tree and try it out!  You have to put 
"AllowOverride All" in your <Directory> config section to let the 
.htaccess file in the ./site/eg installation directory do its work.  

IMPORTANT (FAQ): Make sure that the web server has write access to 
that directory.  Usually a 

 chmod -R 0777 eg

will do the trick :)

=head1 SESSIONS

Cookies are used by default for user $Session support ( see OBJECTS ).  
In order to track a web user and associate server side data 
with that client, the web server sets, and the web client returns 
a 32 byte session id identifier cookie.  This implementation 
is very secure and  may be used in secure HTTPS transactions, 
and made stronger with SecureSession and ParanoidSession 
settings (see CONFIG ).

However good cookies are for this kind of persistent
state management between HTTP requests, they have long 
been under fire for security risks associated with
JavaScript security exploits and privacy abuse by 
large data tracking companies. 

Because of these reasons, web users will sometimes turn off
their cookies, rendering normal ASP session implementations
powerless, resulting in a new $Session generated every request.
This is not good for ASP style sessions.

=head2 Cookieless Sessions

 *** See WARNING Below ***

So we now have more ways to track sessions with the 
SessionQuery* CONFIG settings, that allow a web developer 
to embed the session id in URL query strings when use 
of cookies is denied.  The implementations work such that
if a user has cookies turned on, then cookies will be 
used, but for those users with cookies turned off,
the session ids will be parsed into document URLs.

The first and easiest method that a web developer may use 
to implement cookieless sessions are with SessionQueryParse*
directives which enable Apache::ASP to the parse the session id
into document URLs on the fly.  Because this is resource
inefficient, there is also the SessionQuery* directives
that may be used with the $Server->URL($url,\%params) method to 
generate custom URLs with the session id in its query string.

To see an example of these cookieless sessions in action, 
check out the ./site/eg/cookieless_session.asp example.

 *** WARNING ***

If you do use these methods, then be VERY CAREFUL
of linking offsite from a page that was accessed with a 
session id in a query string.  This is because this session
id will show up in the HTTP_REFERER logs of the linked to 
site, and a malicious hacker could use this information to
compromise the security of your site's $Sessions, even if 
these are run under a secure web server.  

In order to shake a session id off an HTTP_REFERER for a link 
taking a user offsite, you must point that link to a redirect 
page that will redirect a user, like so:

 <% 
    # "cross site scripting bug" prevention
    my $sanitized_url = 
	$Server->HTMLEncode($Response->QueryString('OffSiteUrl'));
 %>
 <html>
 <head>
 <meta http-equiv=refresh content='0;URL=<%=$sanitized_url%>'>
 </head>
 <body>	
	Redirecting you offsite to 
	<a href=<%=$sanitized_url%> >here</a>...
 </body>
 </html>

Because the web browser visits a real page before being redirected
with the <meta> tag, the HTTP_REFERER will be set to this page.
Just be sure to not link to this page with a session id in its
query string.  

Unfortunately a simple $Response->Redirect() will not work here,
because the web browser will keep the HTTP_REFERER of the 
original web page if only a normal redirect is used.

=head1 XML/XSLT

=head2 Custom Tags with XMLSubsMatch

Before XML, there was the need to make HTML markup smarter.
Apache::ASP gives you the ability to have a perl
subroutine handle the execution of any predefined tag,
taking the tag descriptors, and the text contained between,
as arguments of the subroutine.  This custom tag
technology can be used to extend a web developer's abilities
to add dynamic pieces without having to visibly use 
<% %> style code entries.

So, lets say that you have table that 
you want to insert for an employee with contact 
info and the like, you could set up a tag like:

 <my:employee name="Jane" last="Doe" phone="555-2222">
   Jane Doe has been here since 1998.
 </my:employee>

To render it with a custom tag, you would tell 
the Apache::ASP parser to render the tag with a 
subroutine:

  PerlSetVar XMLSubsMatch my:employee

Any colons, ':', in the XML custom tag will turn
into '::', a perl package separator, so the my:employee
tag would translate to the my::employee subroutine, or the 
employee subroutine in the my package.

Then you would create the my::employee subroutine in the my 
perl package or whereever like so

  sub my::employee {
    my($attributes, $body) = @_;
    $Response->Include('employee.inc', $attributes, $body);
  }

  <!-- # employee.inc file somewhere else -->
  <% my($attributes, $body) = @_; %>
  <table>
  <% for('name', 'last', 'phone') { %>
    <tr>
      <td><b><%=ucfirst $_ %></b>:</td>
      <td><%= $attributes->{$_} %></td>
    </tr>
  <% } %>
  <tr><td colspan=2><%= $body %></td></tr>
  </table>
  <!-- # end employee.inc file -->

The $Response->Include() would then delegate the rendering
of the employee to the employee.inc ASP script include.

Though XML purists would not like this custom tag technology
to be related to XML, the reality is that a careful
site engineer could render full XML documents with this
technology, applying all the correct styles that one might
otherwise do with XSLT. 

Custom tags defined in this way can be used as XML tags
are defined with both a body and without as it

  <my:employee>...</my:employee>

and just

  <my:employee/>

These tags are very powerful in that they can also
enclose normal ASP logic, like:

  <my:employee>
    <!-- normal ASP logic -->
    <% my $birthday = &HTTP::Date::time2str(time - 25 * 86400 * 365); %>

    <!-- ASP inserts -->
    This employee has been online for <%= int(rand()*600)+1 %>
    seconds, and was born near <%= $birthday %>.
  </my:employee>   

For an example of this custom XML tagging in action, please check 
out the ./site/eg/xml_subs.asp script.  Note the one limitation
that currently exists is that tags of the same name may not 
be used in each other, but otherwise customs tags may
be used in other custom tags.

=head2 XSLT Tranformations

XML is good stuff, but what can you use it for? The principle is
that by having data and style separated in XML and XSL files, you
can reformat your data more easily in the future, and you 
can render your data in multiple formats, just as easily 
as for your web site, so you might render your site to
a PDA, or a cell phone just as easily as to a browser, and all
you have to do is set up the right XSL stylesheets to do the
transformation (XSLT).

In the first release of XML/XSLT support, Apache::ASP v.19,
ASP scripts may be the source of XML data that the XSL
file transforms.  This transformation is handled by XML::XSLT,
a perl module, and you can see an example of it in action at
the ./site/eg/xslt.xml XML script.  To specify a XSL stylesheet, 
use the setting:

  PerlSetVar XSLT template.xsl

where template.xsl could be any file.  By default this will
XSLT transform all ASP scripts so configured, but you can separate xml
scripts from the rest with the setting:

  PerlSetVar XSLTMatch xml$

where all files with the ending xml would undergo a XSLT transformation.
XSLT tranformations are slow however, so to cache XSLT transformations 
from XML scripts with consistent output, turn on caching:

  PerlSetVar XSLTCacheSize 100

which would allow for the output of 100 transformations to 
be cached.  If the XML data is consistently different as
it might be if it were database driven, then the caching
will have little effect, but for mostly static pages like
real XML docs, this will be a huge win.

Note that XSLT depends on the installation of XML::XSLT,
which in turn depends on XML::DOM, and XML::Parser.  The caching
feature depends on Tie::Cache being installed.

=head2 Reference OSS Implementations

For their huge ground breaking XML efforts, these other XML OSS
projects need mention:

  Cocoon - XML-based web publishing, in Java 
  http://xml.apache.org/cocoon/

  AxKit - XML web publishing with Apache & mod_perl
  http://www.axkit.org/

  XML::XSLT - Core engine that Apache::ASP uses for XSLT
  http://xmlxslt.sourceforge.net/

=head1 CGI

CGI has been the standard way of deploying web applications long before
ASP came along.  CGI.pm is a very useful module that aids developers in 
the building of these applications, and Apache::ASP has been made to 
be compatible with function calls in CGI.pm.  Please see cgi.htm in the 
./site/eg directory for a sample ASP script written almost entirely in CGI.

As of version 0.09, use of CGI.pm for both input and output is seamless
when working under Apache::ASP.  Thus if you would like to port existing
cgi scripts over to Apache::ASP, all you need to do is wrap <% %> around
the script to get going.  This functionality has been implemented so that
developers may have the best of both worlds when building their 
web applications.

Following are some special notes with respect to compatibility with CGI.
Use of CGI.pm in any of these ways was made possible through a great
amount of work, and is not guaranteed to be portable with other perl ASP
implementations, as other ASP implementations will likely be more limited.

=over

=item Query Object Initialization

You may create a CGI.pm $query object like so:

	use CGI;
	my $query = new CGI;

As of Apache::ASP version 0.09, form input may be read in 
by CGI.pm upon initialization.  Before, Apache::ASP would 
consume the form input when reading into $Request->Form(), 
but now form input is cached, and may be used by CGI.pm input
routines.

=item CGI headers

Not only can you use the CGI.pm $query->header() method
to put out headers, but with the CgiHeaders config option
set to true, you can also print "Header: value\n", and add 
similar lines to the top of your script, like:

 Some-Header: Value
 Some-Other: OtherValue

 <html><body> Script body starts here.

Once there are no longer any cgi style headers, or the 
there is a newline, the body of the script begins. So
if you just had an asp script like:

    print join(":", %{$Request->QueryString});

You would likely end up with no output, as that line is
interpreted as a header because of the semicolon.  When doing
basic debugging, as long as you start the page with <html>
you will avoid this problem.

=item print()ing CGI

CGI is notorious for its print() statements, and the functions in CGI.pm 
usually return strings to print().  You can do this under Apache::ASP,
since print just aliases to $Response->Write().  Note that $| has no
affect.

	print $query->header();
	print $query->start_form();

=item File Upload

CGI.pm is used for implementing reading the input from file upload.  You
may create the file upload form however you wish, and then the 
data may be recovered from the file upload by using $Request->Form().
Data from a file upload gets written to a file handle, that may in
turn be read from.  The original file name that was uploaded is the 
name of the file handle.

	my $filehandle = $Request->Form('file_upload_field_name');
	print $filehandle; # will get you the file name
	my $data;
	while(read($filehandle, $data, 1024)) {
		# data from the uploaded file read into $data
	};

Please see the docs on CGI.pm (try perldoc CGI) for more information
on this topic, and ./site/eg/file_upload.asp for an example of its use.

There is a $Request->FileUpload() API extension that you can use to get 
more data about a file upload, so that the following properties are
available for querying:

  my $file_upload = $Request->{FileUpload}{upload_field};
  $file_upload->{BrowserFile}
  $file_upload->{FileHandle}
  $file_upload->{ContentType}

  # only if FileUploadTemp is set
  $file_upload->{TempFile}	

  # whatever mime headers are sent with the file upload
  # just "keys %$file_upload" to find out
  $file_upload->{?Mime-Header?}

Please see the $Request section in OBJECTS for more information.

=back

=head1 PERLSCRIPT

Much work has been done to bring compatibility with ASP applications
written in PerlScript under IIS.  Most of that work revolved around
bringing a Win32::OLE Collection interface to many of the objects
in Apache::ASP, which are natively written as perl hashes.

The following objects in Apache::ASP respond as Collections:

        $Application
	$Session
	$Request->FileUpload *
	$Request->FileUpload('upload_file') *
	$Request->Form
	$Request->QueryString
	$Request->Cookies
	$Response->Cookies
	$Response->Cookies('some_cookie')	

  * FileUpload API Extensions

And as such may be used with the following syntax, as compared
with the Apache::ASP native calls.  Please note the native Apache::ASP
interface is compatible with the deprecated PerlScript interface.

 C = PerlScript Compatibility	N = Native Apache::ASP 
  
 ## Collection->Contents($name) 
 [C] $Application->Contents('XYZ')		
 [N] $Application->{XYZ}

 ## Collection->SetProperty($property, $name, $value)
 [C] $Application->Contents->SetProperty('Item', 'XYZ', "Fred");
 [N] $Application->{XYZ} = "Fred"
	
 ## Collection->GetProperty($property, $name)
 [C] $Application->Contents->GetProperty('Item', 'XYZ')		
 [N] $Application->{XYZ}

 ## Collection->Item($name)
 [C] print $Request->QueryString->Item('message'), "<br>\n\n";
 [N] print $Request->{QueryString}{'message'}, "<br>\n\n";		

 ## Working with Cookies
 [C] $Response->SetProperty('Cookies', 'Testing', 'Extra');
 [C] $Response->SetProperty('Cookies', 'Testing', {'Path' => '/'});
 [C] print $Request->Cookies(Testing) . "<br>\n";
 [N] $Response->{Cookies}{Testing} = {Value => Extra, Path => '/'};
 [N] print $Request->{Cookies}{Testing} . "<br>\n";

Several incompatibilities exist between PerlScript and Apache::ASP:

 > Collection->{Count} property has not been implemented.
 > VBScript dates may not be used for Expires property of cookies.
 > Win32::OLE::in may not be used.  Use keys() to iterate over.
 > The ->{Item} property does not work, use the ->Item() method.

=head1 FAQ

The following are some frequently asked questions
about Apache::ASP.

=head2 Installation

=item Apache errors on the PerlHandler directive ?

You do not have mod_perl correctly installed for Apache.  The PerlHandler
directive in Apache *.conf files is an extension enabled by mod_perl
and will not work if mod_perl is not correctly installed.

Common user errors are not doing a 'make install' for mod_perl, which 
installs the perl side of mod_perl, and not starting the right httpd
after building it.  The latter often occurs when you have an old apache
server without mod_perl, and you have built a new one without copying
over to its proper location.

To get mod_perl, go to http://perl.apache.org

=item Error: no request object (Apache=SCALAR(0x???????):)

Your Apache + mod_perl build is not working properly, 
and is likely a RedHat Linux RPM DSO build.  Make sure
you statically build your Apache + mod_perl httpd,
recompiled fresh from the sources.

=item I am getting a tie or MLDBM / state error message, what do I do?

Make sure the web server or you have write access to the eg directory,
or to the directory specified as Global in the config you are using.
Default for Global is the directory the script is in (e.g. '.'), but should
be set to some directory not under the www server document root,
for security reasons, on a production site.

Usually a 

 chmod -R -0777 eg

will take care of the write access issue for initial testing purposes.

Failing write access being the problem, try upgrading your version
of Data::Dumper and MLDBM, which are the modules used to write the 
state files.

=head2 Sessions

=item How can I use $Session to store complex data structures.

Very carefully.  Please read the $Session documentation in 
the OBJECTS section.  You can store very complex objects
in $Session, but you have to understand the limits, and 
the syntax that must be used to make this happen.

In particular, stay away from statements that that have 
more than one level of indirection on the left side of
an assignment like:

  $Session->{complex}{object} = $data;

=item How can I keep search engine spiders from killing the session manager?

If you want to dissallow session creation for certain non web 
browser user agents, like search engine spiders, you can use an 
init handler like:

  PerlInitHandler "sub { $_[0]->dir_config('NoState', 1) }"

This will configure your environment before Apache::ASP executes
and sees the configuration settings.  You can use the mod_perl
API in this way to configure Apache::ASP at runtime.

=item Insecure dependency in eval while running with - T switch ?

If you are running your mod_perl with "PerlTaintCheck On", which 
is recommended if you are highly concerned about security issues,
you may get errors like "Insecure dependency ... with - T switch".

Apache::ASP automatically untaints data internally so that you
may run scripts with PerlTaintCheck On, but if you are using
state objects like $Session or $Application, you must also
notify MLDBM, which Apache::ASP uses internally, to also 
untaint data read from disk, with this setting:

  $MLDBM::RemoveTaint = 1;

You could put the above line in your global.asa, which is
just like a perl module, outside any event handlers
you define there.

=item How can I use $Session to store a $dbh database handle ?

You cannot use $Session to store a $dbh handle.  This can 
be awkward for those coming from the IIS/NT world, where
you could store just about anything in $Session, but this
boils down to a difference between threads vs. processes.

Database handles often have per process file handles open,
which cannot be shared between requests, so though you 
have stored the $dbh data in $Session, all the other 
initializations are not relevant in another httpd process.

All is not lost! Apache::DBI can be used to cache 
database connections on a per process basis, and will
work for most cases.

=head2 Development

=item How is database connectivity handled?

Database connectivity is handled through perl's DBI & DBD interfaces.
Please see http://www.symbolstone.org/technology/perl/DBI/ for more information.
In the UNIX world, it seems most databases have cross platform support in perl.

DBD::ODBC is often your ticket on Win32.  On UNIX, commercial vendors
like OpenLink Software (http://www.openlinksw.com/) provide the nuts and 
bolts for ODBC.

Database connections can be cached per process with Apache::DBI.

=item What is the best way to debug an ASP application ?

There are lots of perl-ish tricks to make your life developing
and debugging an ASP application easier.  For starters,
you will find some helpful hints by reading the 
$Response->Debug() API extension, and the Debug
configuration directive.

=item How are file uploads handled?

Please see the CGI section.  File uploads are implemented
through CGI.pm which is loaded at runtime only for this purpose.
This is the only time that CGI.pm will be loaded by Apache::ASP,
which implements all other cgi-ish functionality natively.  The
rationale for not implementing file uploads natively is that 
the extra 100K in memory for CGI.pm shouldn't be a big deal if you 
are working with bulky file uploads.

=item How do I access the ASP Objects in general?

All the ASP objects can be referenced through the main package with
the following notation:

 $main::Response->Write("html output");

This notation can be used from anywhere in perl, including routines
registered with $Server->RegisterCleanup().  

You use the normal notation in your scripts, includes, and global.asa:

 $Response->Write("html output");

=item Can I print() in ASP?

Yes.  You can print() from anywhere in an ASP script as it aliases
to the $Response->Write() method.  Using print() is portable with
PerlScript when using Win32::ASP in that environment.

=item Do I have access to ActiveX objects?

Only under Win32 will developers have access to ActiveX objects through
the perl Win32::OLE interface.  This will remain true until there
are free COM ports to the UNIX world.  At this time, there is no ActiveX
for the UNIX world.

=item Can I script in VBScript or JScript ?

Yes, but not with this perl module.  For ASP with other scripting
languages besides perl, you will need to go with a commercial vendor
in the UNIX world.  ChiliSoft at http://www.chilisoft.com/ has one
such solution.  Of course on NT, you get this for free with IIS.

=head2 Support and Production

=item How do I get things I want done?!

If you find a problem with the module, or would like a feature added,
please mail support, as listed in the SUPPORT section, and your 
needs will be promptly and seriously considered, then implemented.

=item What is the state of Apache::ASP?  Can I publish a web site on it?

Apache::ASP has been production ready since v.02.  Work being done
on the module is on a per need basis, with the goal being to eventually
have the ASP API completed, with full portability to ActiveState PerlScript
and MKS PScript.  If you can suggest any changes to facilitate these
goals, your comments are welcome.

=head1 TUNING

A little tuning can go a long way, and can make the difference between
a web site that gets by, and a site that screams with speed.  With
Apache::ASP, you can easily take a poorly tuned site running at
5 hits/second to 25+ hits/second just with the right configuration.

Documented below are some simple things you can do to make the 
most of your site.

For more tips & tricks on tuning Apache and mod_perl, please see the tuning
documents at:

	Stas Bekman's mod_perl guide
	http://perl.apache.org/guide/

	Vivek Khera's mod_perl performance tuning
	http://perl.apache.org/tuning/ 

=head2 $Application & $Session State

Use NoState 1 setting if you don't need the $Application or $Session objects.
State objects such as these tie to files on disk and will incur a performance
penalty.

If you need the state objects $Application and $Session, and if 
running an OS that caches files in memory, set your "StateDir" 
directory to a cached file system.  On WinNT, all files 
may be cached, and you have no control of this.  On Solaris, /tmp is cached
and would be a good place to set the "StateDir" config setting to.  
When cached file systems are used there is little performance penalty 
for using state files.

=head2 High MaxRequests

Set your max requests per child thread or process (in httpd.conf) high, 
so that ASP scripts have a better chance being cached, which happens after 
they are first compiled.  You will also avoid the process fork penalty on 
UNIX systems.  Somewhere between 100 - 1000 is probably pretty good.

=head2 Precompile Scripts

Precompile your scripts by using the Apache::ASP->Loader() routine
documented below.  This will at least save the first user hitting 
a script from suffering compile time lag.  On UNIX, precompiling scripts
upon server startup allows this code to be shared with forked child
www servers, so you reduce overall memory usage, and use less CPU 
compiling scripts for each separate www server process.  These 
savings could be significant.  On my PII300, it takes a couple seconds
to compile 28 scripts upon server startup, with an average of 50K RAM
per compiled script, and this savings is passed on to the child httpd 
servers.

Apache::ASP->Loader() can be called to precompile scripts and
even entire ASP applications at server startup.  Note 
also that in modperl, you can precompile modules with the 
PerlModule config directive, which is highly recommended.

 Apache::ASP->Loader($path, $pattern, %config)

This routine takes a file or directory as its first argument.  If
a file, that file will be compiled.  If a directory, that directory
will be recursed, and all files in it whose file name matches $pattern
will be compiled.  $pattern defaults to .*, which says that all scripts
in a directory will be compiled by default.  

The %config args, are the config options that you want set that affect 
compilation.  These options include Debug, Global, GlobalPackage, 
DynamicIncludes, StatINC, and StatINCMatch.  If your scripts are later 
run with different config options, your scripts may have to be recompiled.

Here is an example of use in a *.conf file:

 <Perl> 
 Apache::ASP->Loader(
	'c:/proj/site', "(asp|htm)\$", 
	Global => '/proj/perllib',
	Debug => 1, # see output when starting apache

	# OPTIONAL configs if you use them in your apache configuration
	# these settings affect how the scripts are compiled and loaded
	GlobalPackage => SomePackageName,
	DynamicIncludes => 1,	
	StatINC => 1,		
	); 
 </Perl>

This config section tells the server to compile all scripts
in c:/proj/site that end in asp or htm, and print debugging
output so you can see it work.  It also sets the Global directory
to be /proj/perllib, which needs to be the same as your real config
since scripts are cached uniquely by their Global directory.  You will 
probably want to use this on a production server, unless you cannot 
afford the extra startup time.

To see precompiling in action, set Debug to 1 for the Loader() and
for your application in general and watch your error_log for 
messages indicating scripts being cached.

=head2 No .htaccess or StatINC

Don't use .htaccess files or the StatINC setting in a production system
as there are many more files touched per request using these features.  I've
seen performance slow down by half because of using these.  For eliminating
the .htaccess file, move settings into *.conf Apache files.

Instead of StatINC, try using the StatINCMatch config, which 
will check a small subset of perl libraries for changes.  This
config is fine for a production environment, and if used well
might only incur a 10-20% performance penalty.

=head2 Turn off Debugging

Turn debugging off by setting Debug to 0.  Having the debug config option
on slows things down immensely.

=head2 RAM Sparing

If you have a lot of scripts, and limited memory, set NoCache to 1,
so that compiled scripts are not cached in memory.  You lose about
10-15% in speed for small scripts, but save at least 10K per cached
script.  These numbers are very rough.  If you use includes, you
can instead try setting DynamicIncludes to 1, which will share compiled
code for includes between scripts.

=head1 SEE ALSO

perl(1), mod_perl(3), Apache(3), MLDBM(3), HTTP::Date(3), CGI(3),
Win32::OLE(3)

=head1 KEYWORDS

Apache, ASP, perl, apache, mod_perl, asp, Active Server Pages, perl, asp, web application, ASP,
session management, Active Server, scripting, dynamic html, asp, perlscript, Unix, Linux, Solaris,
Win32, WinNT, cgi compatible, asp, response, ASP, request, session, application, server,
Active Server Pages

=head1 NOTES

Many thanks to those who helped me make this module a reality.
ASP + Apache, web development could not be better!  Kudos go out to:

 :) Doug MacEachern, for moral support and of course mod_perl
 :) Ryan Whelan, for boldly testing on Unix in the early infancy of ASP
 :) Lupe Christoph, for his immaculate and stubborn testing skills
 :) Bryan Murphy, for being a PerlScript wiz
 :) Francesco Pasqualini, for bringing ASP to CGI
 :) Michael Rothwell, for his love of Session hacking
 :) Lincoln Stein, for his blessed CGI.pm module
 :) Alan Sparks, for knowing when size is more important than speed
 :) Jeff Groves, who put a STOP to user stop button woes
 :) Matt Sergeant, for his great tutorial on PerlScript and love of ASP
 :) Ken Williams, for great teamwork bringing full SSI to the table
 :) Darren Gibbons, the biggest cookie-monster I have ever known.
 :) Doug Silver, for finding most of the bugs.
 :) Marc Spencer, who brainstormed dynamic includes.
 :) Greg Stark, for endless enthusiasm, pushing the module to its limits.
 :) Richard Rossi, for his need for speed & boldly testing dynamic includes.
 :) Bill McKinnon, who understands the finer points of running a web site.
 :) Russell Weiss, for being every so "strict" about his code.
 :) Paul Linder, who is Mr. Clean... not just the code, its faster too !
    Boy was that just the beginning.  Work with him later facilitated better
    session management and XMLSubsMatch custom tag technology.
 :) Tony Merc Mobily, inspiring tweaks to compile scripts 10 times faster
 :) Russell Weiss again, for finding the internal session garbage collection 
    behaving badly with DB_File sensitive i/o flushing requirements.
 :) Dmitry Beransky, for sharable web application includes, ASP on the big.
 :) Adi, who thought to have full admin control over sessions
 :) Matt Arnold, for the excellent graphics !
 :) Remi Fasol + Serge Sozonoff who inspired cookieless sessions.
 :) Matt Sergeant, again, for ever the excellent XML critique.
 :) Stas Bekman, for his beloved guide, and keeping us all worldly.
 :) Gerald Richter, for his Embperl, collaboration and competition!
 :) Geert Josten, for his wonderful work on XML::XSLT
 :) Craig Samuel, at LRN, for his faith in open source for his LCEC.
 :) Vee McMillen, for his tried and true patience.

=head1 SUPPORT

=head2 MAILING LIST ARCHIVE

The mod_perl mailing list archives are located at:

 http://forum.swarthmore.edu/epigone/modperl
 http://www.geocrawler.com/lists/3/web/182/0/
 http://www.egroups.com/group/modperl/

and allow searching for previously asked Apache::ASP
and mod_perl questions.  Often times what may seem to 
be an Apache::ASP issue is really a mod_perl issue.

=head2 EMAIL

Please send any questions or comments to the Apache mod_perl mailing
list at modperl@apache.org with at least Apache::ASP in the 
subject line.  Note that answers to these questions will be archived at 
the above mailing archives, and you may be able to find 
your answer there.

=head2 COMMERCIAL

We are considering a commercial support offering for
Apache::ASP, with varying levels of service, ranging
from 24x7 incident support packages, high priority 
module development, web application tuning and basic
guaranteed email support. 

If you are interested in any of the above commercial 
support offerings, please email asp@chamas.com and
we will pursue an official support channel if there is 
enough interest.  

=head1 SITES USING

What follows is a list of public sites that are using 
Apache::ASP.  If you use the software for your site, and 
would like to show your support of the software by being listed, 
please send your URL to me at joshua@chamas.com and I'll be 
sure to add it to the list.

        Anime Wallpapers dot com
        http://www.animewallpapers.com/

	Chamas Enterprises Inc.		
	http://www.chamas.com

        Direct.it
        http://www.direct.it/

	HCST
	http://www.hcst.net

	International Telecommunication Union
	http://www.itu.int

	Integra
	http://www.integra.ru/

	Internetowa Gielda Samochodowa		
	http://www.gielda.szczecin.pl

        Money FM
        http://www.moneyfm.gr

	Motorsport.com
	http://www.motorsport.com

	Multiple Listing Service of Greater Cincinnati
	http://www.cincymls.com

	NodeWorks - web link monitoring				
	http://nodeworks.com

	OnTheWeb Services
	http://www.ontheweb.nu

	Provillage
	http://www.provillage.com

	Prices for Antiques
	http://www.p4a.com

	redhat.com | support
	http://www.redhat.com/apps/support/

	Samara.RU
	http://portal.samara.ru/

	Sex Shop Online				
	http://www.sex.shop.pl
	
	Spotlight
	http://www.spotlight.com.au

	USCD Electrical & Computer Engineering
	http://ece-local.ucsd.edu

=head1 RESOURCES

Here are some important resources listed related to 
the use of Apache::ASP for publishing web applications:

	mod_perl Apache web module
	http://perl.apache.org

	mod_perl Guide
	http://perl.apache.org/guide/

	mod_perl book
	http://www.modperl.com
	
	Perl Programming Language
	http://www.perl.com

	Apache Web Server
	http://www.apache.org
 
	PerlMonth Online Magazine
	http://www.perlmonth.com

	Apache & mod_perl Reference Cards
	http://www.refcards.com/

	Perl DBI Database Access
	http://www.symbolstone.org/technology/perl/DBI/		


=head1 TODO

There is no specific time frame in which these things will be 
implemented.  Please let me know if any of these is of particular
interest to you, and I will give it higher priority.

=head2 WILL BE DONE 

 + Database storage of $Session & $Application, so web clusters 
   may scale better than the current NFS StateDir implementation
   allows, maybe via Apache::Session.
 + Dumping state of Apache::ASP during an error, and being
   able to go through it with the perl debugger.
 + Investigating possibility of hooking $Session timeout into 
   client/server 401 authentication failure.  Seems like IE 
   caches passwords which makes things tough
 + $Request->ClientCertificate()
 + asp.pl, CGI method of doing asp

=head2 MAY BE DONE

 + VBScript, ECMAScript interpreters
 + allow use of Apache::Session for session management
 + Close integration with HTML::Embperl
 + BerkeleyDB2 integration for state management, maybe getting
   shared memory to work.
 + MailErrorsPower, sends duplicate errors every 1,10,100... occurences
 + MailErrorsPowerPeriod, resets the duplicate errors counter.

=head1 CHANGES

 + = improvement; - = bug fix

=item $VERSION = 1.91; $DATE="07/02/00";

 +Documented XMLSubsMatch & XSLT* configuration
  settings in CONFIG section.

 +XSLT XSL template is now first executed as an 
  ASP script just like the XML scripts.  This is 
  just one step away now from implementing XSP logic.

 +$Server->Execute and $Server->Transfer API extensions
  implemented.  Execute is the same as $Request->Include()
  and $Server->Transfer is like an apache internal redirect
  but keeps the current ASP objects for the next script.

  Added examples, transfer.htm, and modified dynamic_includes.htm.

 +Better compile time error debugging with Debug 2 or -2.
  Will hilite/link the buggy line for global.asa errors, 
  include errors, and XML/XSLT errors just like with 
  ASP scripts before.

 +Nice source hiliting when viewing source for the example
  scripts.

 +Runtime string writing optimization for static HTML going
  through $Response.

 +New version numbering just like everyone else.  Starting at 1.91
  since I seem to be off by a factor of 10, last release would have
  been 1.9.

=item $VERSION = 0.19; $DATE="NOT RELEASED";

 +XMLSubsMatch and XSLT* settings documented in 
  the XML/XSLT section of the site/README.

 -XMLSubsMatch will strip parens in a pattern match
  so it does not interfere with internal matching use.

 +XSLT integration allowing XML to be rendered by XSLT
  on the fly.  XSLT specifies XSL file to transform XML.
  XSLTMatch is a regexp that matches XML file names, like \.xml$,
  which will be transformed by XSLT setting, default .*
  
  XSLTCacheSize when specified uses Tie::Cache to cached XML DOMs 
  internally and cache XSLT transformations output per XML/XSL 
  combination.  XML DOM objects can take a lot of RAM, so use
  this setting judiciously like setting to 100.  Definitely 
  experiment with this value.

 +More client info in the error mail feature, including
  client IP, form data, query string, and HTTP_* client headers

 +With Time::HiRes loaded, and Debug set to non 0, 
  will add a <!-- Apache::ASP served request in xx.xx seconds -->
  to text/html output, similar to Cocoon, per user request  
  Will also add this to the system debug error log output
  when Debug is < 0

 -bug fix on object initialization optimization earlier
  in this release, that was introduced for faster event
  handler execution.

 +Apache::ASP::Parse() takes a file name, scalar, or
  scalar ref for arguments of data to parse for greater
  integration ability with other applications.

 +PodComments optimization, small speed increase at
  compilation time.

 +String optimization on internal rendering that avoids 
  unnecessary copying of static html, by using refs.  Should 
  make a small difference on sites with large amounts of 
  static html.

 +CompressGzip setting which, when Compress::Zlib is installed,
  will compress text/html automatically going out to the web
  browser if the client supports gzip encoding.

 ++Script_OnFlush event handler, and auxiliary work optimizing
  asp events in general.  $Response->{BinaryRef} created which
  is a reference to outgoing output, which can be used 
  to modify the data at runtime before it goes out to the client. 

 +Some code optimizations that boost speed from 22 to 24 
  hits per second when using Sessions without $Application,
  on a simple hello world benchmark on a WinNT PII300.

 ++Better SessionManagement, more aware of server farms that 
  don't have reliable NFS locking.  The key here is to have only
  one process on one server in charge of session garbage collection
  at any one time, and try to create this situation with a snazzy
  CleanupMaster routine.  This is done by having a process register
  itself in the internal database with a server key created at
  apache start time.  If this key gets stale, another process can 
  become the master, and this period will not exceed the period
  SessionTimeout / StateManager.

  ** Work on session manager sponsored by LRN, http://www.lrn.com.  **
  ** This work was used to deploy a server farm in production with  **
  ** NFS mounted StateDir. Thanks to Craig Samuel for his belief in **
  ** open source. :)                                                **

  Future work for server farm capabilities might include breaking
  up the internal database into one of 256 internal databases 
  hashed by the first 2 chars of the session id.  Also on the plate
  is Apache::Session like abilities with locking and/or data storage
  occuring in a SQL database.  The first dbs to be done will include
  MySQL & Oracle.

 +Better session security which will create a new session id for an 
  incoming session id that does not match one already seen.  This will
  help for those with Search engines that have bookmarked
  pages with the session ids in the query strings.  This breaks away
  from standard ASP session id implementation which will automatically
  use the session id presented by the browser, now a new session id will
  be returned if the presented one is invalid or expired.

 -$Application->GetSession will only return a session if
  one already existed.  It would create one before by default.

 +Script_OnFlush global.asa event handler, and $Response->{BinaryRef}
  member which is a scalar reference to the content about to be flushed.
  See ./site/eg/global.asa for example usage, used in this case to
  insert font tags on the fly into the output.

 +Highlighting and linking of line error when Debug is set to 2 or -2.

 --removed fork() call from flock() backup routine? How did 
   that get in there?  Oh right, testing on Win32. :(
   Very painful lesson this one, sorry to whom it may concern.

 +$Application->SessionCount support turned off by default
  must enable with SessionCount config option.  This feature
  puts an unnecessary load on busy sites, so not default 
  behavior now.  

 ++XMLSubsMatch setting that allows the developer to 
  create custom tags XML style that execute perl subroutines.
  See ./site/eg/xml_subs.asp

 +MailFrom config option that defaults the From: field for 
  mails sent via the Mail* configs and $Server->Mail()

 +$Server->Mail(\%mail, %smtp_args) API extension

 +MailErrorsTo & MailAlertTo now can take comma
  separated email addresses for multiple recipients.

 -tracking of subroutines defined in scripts and includes so 
  StatINC won't undefine them when reloading the GlobalPackage, 
  and so an warning will be logged when another script redefines 
  the same subroutine name, which has been the bane of at least
  a few developers.

 -Loader() will now recompile dynamic includes that 
  have changed, even if main including script has not.
  This is useful if you are using Loader() in a 
  PerlRestartHandler, for reloading scripts when
  gracefully restarting apache.

 -Apache::ASP used to always set the status to 200 by 
  default explicitly with $r->status().  This would be 
  a problem if a script was being used to as a 404 
  ErrorDocument, because it would always return a 200 error
  code, which is just wrong.  $Response->{Status} is now 
  undefined by default and will only be used if set by 
  the developer.  

  Note that by default a script will still return a 200 status, 
  but $Response->{Status} may be used to override this behavior.

 +$Server->Config($setting) API extension that allows developer
  to access config settings like Global, StateDir, etc., and is a 
  wrapper around Apache->dir_config($setting)

 +Loader() will log the number of scripts
  recompiled and the number of scripts checked, instead
  of just the number of scripts recompiled, which is
  misleading as it reports 0 for child httpds after
  a parent fork that used Loader() upon startup.  	

 -Apache::ASP->Loader() would have a bad error if it didn't load 
  any scripts when given a directory, prints "loaded 0 scripts" now

=item $VERSION = 0.18; $DATE="02/03/00";

 +Documented SessionQuery* & $Server->URL() and 
  cleaned up formatting some, as well as redoing
  some of the sections ordering for better readability.
  Document the cookieless session functionality more
  in a new SESSIONS section.  Also documented new 
  FileUpload configs and $Request->FileUpload collection.
  Documented StatScripts.

 +StatScripts setting which if set to 0 will not reload
  includes, global.asa, or scripts when changed.

 +FileUpload file handles cleanup at garbage collection
  time so developer does not have to worry about lazy coding
  and undeffing filehandles used in code.  Also set 
  uploaded filehandles to binmode automatically on Win32 
  platforms, saving the developer yet more typing.

 +FileUploadTemp setting, default 0, if set will leave
  a temp file on disk during the request, which may be 
  helpful for processing by other programs, but is also
  a security risk in that others could potentially read 
  this file while the script is running. 

  The path to the temp file will be available at
  $Request->{FileUpload}{$form_field}{TempFile}.
  The regular use of file uploads remains the same
  with the <$filehandle> to the upload at 
  $Request->{Form}{$form_field}.

 +FileUploadMax setting, default 0, currently an 
  alias for $CGI::POST_MAX, which determines the 
  max size for a file upload in bytes.  

 +SessionQueryParse only auto parses session-ids
  into links when a session-id COOKIE is NOT found.
  This feature is only enabled then when a user has
  disabled cookies, so the runtime penalty of this
  feature won't drag down the whole site, since most
  users will have cookies turned on.   

 -StatINC & StatINCMatch will not undef Fnctl.pm flock 
  functions constants like O_RDWR, because the code references
  are not well trackable.  This would result in sporadic 500 server
  errors when a changed module was reloaded that imported O_* flock 
  functions from Fnctl.

 +SessionQueryParse & SessionQueryParseMatch
  settings that enable auto parsing session ids into 
  URLs for cookieless sessions.  Will pick up URLs in 
  <a href>, <area href>, <form action>, <frame src>,
  <iframe src>, <img src>, <input src>, <link href>
  $Response->Redirect($URL) and the first URL in 
  script tags like <script>*.location.href=$URL</script>

  These settings require that buffering be enabled, as
  Apache::ASP will parse through the buffer to parse the URLs.

  With SessionQueryParse on, it will just parse non-absolute
  URLs, but with SessionQueryParseMatch set to some server
  url regexp, like ^http://localhost , will also parse
  in the session id for URLs that match that.

  When testing, the performance hit from this parsing
  a script dropped from 12.5 hits/sec on my WinNT box
  to 11.7 hits per second for 1K of buffered output.
  The difference is .007 of my PII300's processing power
  per second.

  For 10K of output then, my guess is that this speed
  of script, would be slowed to 6.8 hits per second.
  This kind of performance hit would also slow a
  script running at 40 hits per second on a UNIX box
  to 31 hits/sec for 1K, and to 11 hits/sec for 10K parsed.

  Your mileage may vary and you will have to test the difference
  yourself.  Get yourself a valid URL with a session-id in
  it, and run it through ab, or Socrates, with SessionQuery
  turned on, and then with SessionQueryParse set to see 
  the difference.  SessionQuery just enables of session id
  setting from the query string but will not auto parse urls.

 -If buffering, Content-Length will again be set.
  It broke, probably while I was tuning in the past 
  couple versions.

 +UseStrict setting compiles all scripts including
  global.asa with "use strict" turned on for catching
  more coding errors.  With this setting enabled,
  use strict errors die during compilation forcing
  Apache::ASP to try to recompile the script until
  successful.

 -Object use in includes like $Response->Write() 
  no longer error with "use strict" programming.  

 +SessionQuery config setting with $Server->URL($url, { %params } ) 
  alpha API extensions to enable cookieless sessions.

 +Debugging not longer produces internal debugging
  by default.  Set to -1,-2 for internal debugging
  for Debug settings 1 & 2.

 +Both StateSerializer & StateDB can be changed 
  without affecting a live web site, by storing 
  the configurations for $Application & $Session 
  in an internal database, so that if $Session was
  created with SDBM_File for the StateDB (default),
  it will keep this StateDB setting until it ends.

 +StateSerializer config setting.  Default Data::Dumper,
  can also be set to Storable.  Controls how data is
  serialized before writing to $Application & $Session.

 +Beefed up the make test suite.

 +Improved the locking, streamlining a bit of the 
  $Application / $Session setup process.  Bench is up to 
  22 from 21 hits / sec on dev NT box.

 +Cut more fat for faster startup, now on my dev box 
  I get 44 hits per sec Apache::ASP vs. 48 Embperl 
  vs. 52 CGI via Apache::Registry for the HelloWorld Scripts.

 -Improved linking for the online site documentation, 
  where a few links before were bad.

=item $VERSION = 0.17; $DATE="11/15/99";

 ++20%+ faster startup script execution, as measured by the 
  HelloWorld bench.  I cut a lot of the fat out of 
  the code, and is now at least 20% faster on startup 
  both with and without state.

  On my dev (NT, apache 1.3.6+mod_perl) machine, I now get:

	42 hits per sec on Apache::ASP HelloWorld bench
	46 hits per sec on Embperl (1.2b10) and
	51 hits per sec for CGI Apache::Registry scripts  

  Before Apache::ASP was clocking some 31 hits per sec.
  Apache::ASP also went from 75 to 102 hits per second 
  on Solaris.

 +PerlTaintCheck On friendly.  This is mod_perl's way 
  of providing -T taint checking.  When Apache::ASP
  is used with state objects like $Session or $Application,
  MLDBM must also be made taint friendly with:

    $MLDBM::RemoveTaint = 1;

  which could be put in the global.asa.  Documented.

 +Added $Response->ErrorDocument($error_code, $uri_or_string) 
  API extension which allows for setting of Apache's error
  document at runtime.  This is really just a wrapper 
  for Apache->custom_response() renamed so it syncs with
  the Apache ErrorDocument config setting.  Updated
  documentation, and added error_document.htm example.

 =OrderCollections setting was added, but then REMOVED
  because it was not going to be used.  It bound 
  $Request->* collections/hashes to Tie::IxHash, so that data
  in those collections would be read in the order the 
  browser sent it, when eaching through or with keys.

 -global.asa will be reloaded when changed.  This broke
  when I optimized the modification times with (stat($file))[9]
  rather than "use File::stat; stat($file)->mtime"

 -Make Apache::ASP->Loader() PerlRestartHandler safe,
  had some unstrict code that was doing the wrong thing.

 -IncludesDir config now works with DynamicIncludes.

 +DebugBufferLength feature added, giving control to 
  how much buffered output gets shown when debugging errors.

 ++Tuning of $Response->Write(), which processes all
  static html internally, to be almost 50% faster for
  its typical use, when BufferingOn is enabled, and 
  CgiHeaders are disabled, both being defaults.

  This can show significant speed improvements for tight
  loops that render ASP output.

 +Auto linking of ./site/eg/ text to example scripts
  at web site.

 +$Application->GetSession($session_id) API extension, useful
  for managing active user sessions when storing session ids
  in $Application.  Documented.

 -disable use of flock() on Win95/98 where it is unimplemented

 -@array context of $Request->Form('name') returns
  undef when value for 'name' is undefined.  Put extra
  logic in there to make sure this happens. 

=item $VERSION = 0.16; $DATE="09/22/99";

 -$Response->{Buffer} and PerlSetVar BufferingOn
  configs now work when set to 0, to unbuffer output,
  and send it out to the web client as the script generates it.

  Buffering is enabled by default, as it is faster, and
  allows a script to error cleanly in the middle of execution.  

 +more bullet proof loading of Apache::Symbol, changed the 
  way Apache::ASP loads modules in general.  It used to 
  check for the module to load every time, if it hadn't loaded
  successfully before, but now it just tries once per httpd,
  so the web server will have to be restarted to see new installed
  modules.  This is just for modules that Apache::ASP relies on.

  Old modules that are changed or updated with an installation
  are still reloaded with the StatINC settings if so configured. 

 +ASP web site wraps <font face="courier new"> around <pre>
  tags now to override the other font used for the text
  areas.  The spacing was all weird in Netscape before
  for <pre> sections.

 -Fixed Content-Length calculation when using the Clean
  option, so that the length is calculated after the HTML
  is clean, not before.  This would cause a browser to 
  hang sometimes.

 +Added IncludesDir config option that if set will also be
  used to check for includes, so that includes may easily be
  shared between applications.  By default only Global and 
  the directory the script is in are checked for includes.

  Also added IncludesDir as a possible configuration option
  for Apache::ASP->Loader()

 -Re-enabled the Application_OnStart & OnEnd events, after
  breaking them when implementing the AllowApplicationState
  config setting.

 +Better pre-fork caching ... StatINC & StatINCMatch are now 
  args for Apache::ASP->Loader(), so StatINC symbols loading
  may be done pre-fork and shared between httpds.  This lowers
  the child httpd init cost of StatINC.  Documented.

 +Made Apache::ASP Basic Authorization friendly so authentication
  can be handled by ASP scripts.  If AuthName and AuthType Apache
  config directives are set, and a $Response->{Status} is set to 
  401, a user will be prompted for username/password authentication
  and the entered data will show up in ServerVariables as:
    $env = $Request->ServerVariables
    $env->{REMOTE_USER} = $env->{AUTH_USER} = username
    $env->{AUTH_PASSWD} = password
    $env->{AUTH_NAME}   = your realm
    $env->{AUTH_TYPE}   = 'Basic'

  This is the same place to find auth data as if Apache had some 
  authentication handler deal with the auth phase separately.

 -MailErrorsTo should report the right file now that generates
  the error.

=item $VERSION = 0.15; $DATE="08/24/99";

 --State databases like $Session, $Application are 
  now tied/untied to every lock/unlock triggered by read/write 
  access.  This was necessary for correctness issues, so that 
  database file handles are flushed appropriately between writes
  in a highly concurrent multi-process environment.

  This problem raised its ugly head because under high volume, 
  a DB_File can become corrupt if not flushed correctly.  
  Unfortunately, there is no way to flush SDBM_Files & DB_Files 
  consistently other than to tie/untie the databases every access.

  DB_File may be used optionally for StateDB, but the default is
  to use SDBM_File which is much faster, but limited to 1024 byte
  key/value pairs.

  For SDBM_Files before, if there were too many concurrent 
  writes to a shared database like $Application, some of the 
  writes would not be saved because another process
  might overwrite the changes with its own.

  There is now a 10 fold performance DECREASE associated
  with reading from and writing to files like $Session 
  and $Application.  With rough benchmarks I can get about
  100 increments (++) now per second to $Session->{count}, where
  before I could get 1000 increments / second.  

  You can improve this if you have many reads / writes happening
  at the same time, by placing locking code around the group like
  
	$Session->Lock();
	$Session->{count}++;
	$Session->{count}++;
	$Session->{count}++;
	$Session->UnLock();	

  This method will reduce the number of ties to the $Session database
  from 6 to 1 for this kind of code, and will improve the performance
  dramatically.

  Also, instead of using explicit $Session locking, you can 
  create an automatic lock on $Session per script by setting
  SessionSerialize in your config to 1.  The danger here is
  if you have any long running scripts, the user will have
  to wait for it to finish before another script can be run.

  To see the number of lock/unlocks or ties/unties to each database
  during a script execution, look at the last lines of debug output
  to your error log when Debug is set to 1.  This can help you
  performance tweak access to these databases.

 +Updated documentation with new config settings and
  API extensions.

 +Added AllowApplicationState config option which allows
  you to leave $Application undefined, and will not
  execute Application_OnStart or Application_OnEnd.
  This can be a slight performance increase of 2-3% if
  you are not using $Application, but are using $Session.

 +Added $Session->Lock() / $Session->UnLock() API routines
  necessary additions since access to session is not
  serialized by default like IIS ASP.  Also prompted
  by change in locking code which retied to SDBM_File
  or DB_File each lock.  If you $Session->Lock / UnLock
  around many read/writes, you will increase performance.

 +Added StateCache config which, if set will cache
  the file handle locks for $Application and an internal 
  database used for tracking $Session info.  This caching can 
  make an ASP application perform up to 10% faster,
  at a cost of each web server process holding 2 more 
  cached file handles open, per ASP application using
  this configuration.  The data written to or read from
  these state databases is not cached, just the locking 
  file handles are held open.

 -Added in much more locking in session manager 
  and session garbage collector to help avoid collisions
  between the two.  There were definite windows that the
  two would collide in, during which bad things could 
  happen on a high volume site.

 -Fixed some warnings in DESTROY and ParseParams()

=item $VERSION = 0.14; $DATE="07/29/99";

 -CGI & StatINC or StatINCMatch would have bad results
  at times, with StatINC deleting dynamically compiled
  CGI subroutines, that were imported into other scripts
  and modules namespaces.

  A couple tweaks, and now StatINC & CGI play nice again ;)
  StatINCMatch should be safe to use in production with CGI. 
  This affects in particular environments that use file upload, 
  since CGI is loaded automatically by Apache::ASP to handle 
  file uploads.

  This fix should also affect other seemingly random 
  times when StatINC or StatINCMatch don't seem to do 
  the right thing.

 +use of ASP objects like $Response are now "use strict"
  safe in scripts, while UniquePackages config is set.

 +Better handling of "use strict" errors in ASP scripts.
  The error is detected, and the developer is pointed to the 
  Apache error log for the exact error.  

  The script with "use strict" errors will be recompiled again.  Its seems 
  though that "use strict" will only throw its error once, so that a script 
  can be recompiled with the same errors, and work w/o any use strict
  error messaging.  

=item $VERSION = 0.12; $DATE="07/01/99";

 -Compiles are now 10 +times faster for scripts with lots of big
  embedded perl blocks <% #perl %>

  Compiles were slow because of an old PerlScript compatibility
  parsing trick where $Request->QueryString('hi')->{item}
  would be parsed to $Request->QueryString('hi') which works.
  I think the regexp that I was using had O(n^2) characteristics
  and it took a really big perl block to 10 +seconds to parse
  to understand there was a problem :(

  I doubt anyone needed this compatibility, I don't even see
  any code that looks like this in the online PerlScript examples,
  so I've commented out this parsing trick for now.  If you 
  need me to bring back this functionality, it will be in the 
  form of a config setting.

  For information on PerlScript compatibility, see the PerlScript
  section in the ASP docs.

 -Added UniquePackages config option, that if set brings back 
  the old method of compiling each ASP script into its own
  separate package.  As of v.10, scripts are compiled by default
  into the same package, so that scripts, dynamic includes & global.asa
  can share globals.  This BROKE scripts in the same ASP Application
  that defined the same sub routines, as their subs would redefine
  each other.  

  UniquePackages has scripts compiled into separate perl packages,
  so they may define subs with the same name, w/o fear of overlap.
  Under this settings, scripts will not be able to share globals.  

 -Secure field for cookies in $Response->Cookies() must be TRUE to 
  force cookie to be secure.  Before, it just had to be defined, 
  which gave wrong behavior for Secure => 0. 

 +$Response->{IsClientConnected} set to one by default.  Will
  work out a real value when I upgrade to apache 1.3.6.  This
  value has no meaning before, as apache aborts the perl code
  when a client drops its connection in earlier versions.

 +better compile time debugging of dynamic includes, with 
  Debug 2 setting

 +"use strict" friendly handling of compiling dynamic includes
  with errors

=item $VERSION = 0.11; $DATE="06/24/99";

 +Lots of documentation updates

 +The MailHost config option is the smtp server used for 
  relay emails for the Mail* config options.

 +MailAlertTo config option used for sending a short administrative
  alert for an internal ASP error, server code 500.  This is the 
  compliment to MailErrorsTo, but is suited for sending a to a
  small text based pager.  The email sent by MailErrorsTo would
  then be checked by the web admin for quick response & debugging
  for the incident. 

  The MailAlertPeriod config specifies the time in minutes during 
  which only one alert will be sent, which defaults to 20.

 +MailErrorsTo config options sends the results of a 500 error
  to the email address specified as if Debug were set to 2.
  If Debug 2 is set, this config will not be on, as it is
  for production use only.  Debug settings less than 2 only 
  log errors to the apache server error log.

 -StatINCMatch / StatINC can be used in production and work
  even after a server graceful restart, which is essential for 
  a production server.

 -Content-Length header is set again, if BufferingOn is set, and
  haven't $Response->Flush()'d.  This broke when I introduce
  the Script_OnEnd event handler.

 +Optimized reloading of the GlobalPackage perl module upon changes, 
  so that scripts and dynamic includes don't have to be recompiled.  
  The global.asa will still have to be though.  Since we started
  compiling all routines into a package that can be named with
  GlobalPackage, we've been undeffing compiled scripts and includes
  when the real GlobalPackage changed on disk, as we do a full sweep
  through the namespace.  Now, we skip those subs that we know to 
  be includes or scripts. 

 -Using Apache::Symbol::undef() to undefine precompiled scripts
  and includes when reloading those scripts.  Doing just an undef() 
  would sometimes result in an "active subroutine undef" error.
  This bug came out when I started thrashing the StatINC system
  for production use.

 +StatINCMatch setting created for production use reloading of
  perl modules.  StatINCMatch allows StatINC reloading of a
  subset of all the modules defined in %INC, those that match
  $module =~ /$StatINCMatch/, where module is some module name
  like Class/Struct.pm

 +Reoptimized pod comment parsing.  I slowed it down to sync
  lines numbers in the last version, but found another corner I could cut.

=item $VERSION = 0.10; $DATE="05/24/99";

 += improvement; - = bug fix

 +Added index.html file to ./eg to help people wade through
  the examples.  This one has been long overdue.

 +Clean config option, or setting $Response->{Clean} to 1 - 9,
  uses HTML::Clean to compress text/html output of ASP scripts.
  I like the Clean 1 setting which is lightweight, stripping 
  white space for about 10% compression, at a cost of less than
  a 5% performance penalty.

 +Using pod style commenting no longer confuses the line
  numbering.  ASP script line numbers are almost exactly match
  their compiled perl version, except that normal inline includes
  (not dynamic) insert extra text which can confuse line numbering.
  If you want perl error line numbers to entirely sync with your 
  ASP scripts, I would suggest learning how to use dynamic includes,
  as opposed to inline includes.

 -Wrapped StatINC reloading of libs in an eval, and capturing
  error for Debug 2 setting.  This makes changing libs with StatINC
  on a little more friendly when there are errors. 

 -$Request->QueryString() now stores multiple values for the 
  same key, just as $Request->Form() has since v.07.  In
  wantarray() context like @vals = $Request->QueryString('dupkey'),
  @vals will store whatever values where associated with dupkey
  in the query string like (1,2) from: ?dupkey=1&dupkey=2

 +The GlobalPackage config directive may be defined
  to explicitly set the perl module that all scripts and global.asa
  are compiled into.

 -Dynamic includes may be in the Global directory, just like
  normal includes.

 +Perl script generated from asp scripts should match line
  for line, seen in errors, except when using inline (default) 
  includes, pod comments, or <% #comment %> perl comments, which 
  will throw off the line counts by adding text, removing
  text, or having an extra newline added, respectively.

 -Script_OnEnd may now send output to the browser.  Before
  $main::Response->End() was being called at the end of the
  main script preventing further output.

++All scripts are compiled as routines in a namespace uniquely
  defined by the global.asa of the ASP application.  Thus,
  scripts, includes, and global.asa routines will share
  all globals defined in the global.asa namespace.   This means
  that globals between scripts will be shared, and globals
  defined in a global.asa will be available to scripts.

  Scripts used to have their own namespace, thus globals
  were not shared between them.

 +a -o $output_dir switch on the ./cgi/asp script allows
  it to execute scripts and write their output to an output
  directory.  Useful for building static html sites, based on
  asp scripts.  An example use would be:

    asp -b -o out *.asp

  Without an output directory, script output is written to STDOUT


=item $VERSION = 0.09; $DATE="04/22/99";

 +Updated Makefile.PL optional modules output for CGI & DB_File

 +Improved docs on $Response->Cookies() and $Request->Cookies()

 +Added PERFORMANCE doc to main README, and added sub section
  on precompiling scripts with Apache::ASP->Loader()

 +Naming of CompileIncludes switched over to DynamicIncludes 
  for greater clarity.

 +Dynamic includes can now reference ASP objects like $Session
  w/o the $main::* syntax.  These subs are no longer anonymous
  subs, and are now compiled into the namespace of the global.asa package.

 +Apache::ASP->Loader() precompiles dynamic includes too. Making this work
  required fixing some subtle bugs / dependencies in the compiling process.

 +Added Apache::ASP->Loader() similar to Apache::RegistryLoader for
  precompiling ASP scripts.  Precompile a whole site at server 
  startup with one function call.

 +Prettied the error messaging with Debug 2.

 +$Response->Debug(@args) debugging extension, which
  allows a developer to hook into the module's debugging,
  and only have @args be written to error_log when Debug is greater
  than 0.

 -Put write locking code around State writes, like $Session
  and $Application.  I thought I fixed this bug a while ago.

 -API change: converted $Session->Timeout() and $Session->SessionID() 
  methods into $Session->{Timeout} and $Session->{SessionID} properties.
  The use of these properties as methods is deprecated, but 
  backwards compatibility will remain.  Updated ./eg/session.asp
  to use these new properties.

 +Implemented $Response->{PICS} which if set sends out a PICS-Label
  HTTP header, useful for ratings.

 +Implemented $Response->{CacheControl} and $Response->{Charset} members.
  By default, CacheControl is 'private', and this value gets sent out
  every request as HTTP header Cache-Control.  Charset appends itself
  onto the content type header.

 +Implemented $Request->BinaryRead(), $Request->{TotalBytes},
  documented them, and updated ./eg/form.asp for an example usage. 

 +Implemented $Response->BinaryWrite(), documented, and created
  and example in ./eg/binary_write.htm

 +Implemented $Server->MapPath() and created example of its use
  in ./eg/server.htm

 -$Request->Form() now reads file uploads correctly with 
  the latest CGI.pm, where $Request->Form('file_field') returns
  the actual file name uploaded, which can be used as a file handle
  to read in the data.  Before, $Request->Form('file_field') would
  return a glob that looks like *Fh::filename, so to get the file
  name, you would have to parse it like =~ s/^\*Fh\:\://,
  which you no longer have to do.  As long as parsing was done as
  mentioned, the change should be backwards compatible.

 +Updated  +enhanced documentation on file uploads.  Created extra
  comments about it as an FAQ, and under $Response->Form(), the latter
  being an obvious place for a developer to look for it.

 +Updated ./eg/file_upload.asp to show use of non file form data, 
  with which we had a bug before.

 +Finished retieing *STDIN to cached STDIN contents, so that 
  CGI input routines may be used transparently, along side with
  use of $Request->Form()

 +Cleaned up and optimized $Request code

 +Updated documentation for CGI input & file uploads.  Created
  file upload FAQ.

 +Reworked ./eg/cgi.htm example to use CGI input routines
  after doing a native read of STDIN.

 ++Added dynamic includes with <!--include file=file args=@args-->
  extension.  This style of include is compiled as an anonymous sub & 
  cached, and then executed with @args passed to the subroutine for 
  execution.  This is include may also be rewritten as a new API 
  extension: $Response->Include('file', @args)

 +Added ./eg/compiled_includes.htm example documenting new dynamic includes.

 +Documented SSI: native file includes, and the rest with filtering 
  to Apache::SSI

 +Turned the documentation of Filter config to value of Off so 
  people won't cut and paste the On config by default.

 +Added SecureSession config option, which forces session cookie to 
  be sent only under https secured www page requests.

 +Added StateDB config option allows use of DB_File for $Session, since 
  default use of SDBM_File is limited.  See StateDB in README.

 +file include syntax w/o quotes supported like <!--#include file=test.inc-->

 +Nested includes are supported, with includes including each other.
  Recursive includes are detected and errors out when an include has been 
  included 100 times for a script.  Better to quit early than 
  have a process spin out of control. (PORTABLE ? probably not)

 +Allow <!--include file=file.inc--> notation w/o quotes around file names

 -PerlSetEnv apache conf setting now get passed through to $Request->ServerVariables.
  this update has ServerVariables getting data from %ENV instead of $r->cgi_env

 +README FAQ for PerlHandler errors


=item $VERSION = 0.08; $DATE="02/06/99";

 ++SSI with Apache::Filter & Apache::SSI, see config options & ./eg files
  Currently filtering only works in the direction Apache::ASP -> Apache::SSI,
  will not work the other way around, as SSI must come last in a set of filters

 +SSI file includes may reference files in the Global directory, better code sharing

 - <% @array... %> no longer dropped from code.

 +perl =pod comments are stripped from script before compiling, and associated
  PodComments configuration options.

 +Command line cgi/asp script takes various options, and allows execution
  of multiple asp scripts at one time.  This script should be used for
  command line debugging.  This is also the beginning of building
  a static site from asp scripts with the -b option, suppressing headers.

 +$Response->AddHeader('Set-Cookie') works for multiple cookies.

 -$Response->Cookies('foo', '0') works, was dropping 0 because of boolean test

 -Fixed up some config doc errors.


=item $VERSION = 0.07; $DATE="01/20/99";

 -removed SIG{__WARN__} handler, it was a bad idea.

 -fixes file locking on QNX, work around poor flock porting

 +removed message about Win32::OLE on UNIX platforms from Makefile.PL

 -Better lock garbage collection.  Works with StatINC seamlessly.

 -Multiple select forms now work in array context with $Response->Form()
	@values = $Response->Form('multi');

 -Better CGI.pm compatibility with $r->header_out('Content-type'),
  improved garbage collection under modperl, esp. w/ file uploads


=item $VERSION = 0.06; $DATE="12/21/98";

 +Application_OnStart & Application_OnEnd event handlers support.

 -Compatible with CGI.pm 2.46 headers() 

 -Compatible with CGI.pm $q = new CGI({}), caveat: does not set params 

 +use strict; followed by use of objects like $Session is fine.

 -Multiple cookies may be set per script execution.

 +file upload implemented via CGI.pm

 ++global.asa implemented with events Session_OnStart and Session_OnEnd
  working appropriately.

 +StateDir configuration directive implemented.
  StateDir allows the session state directory to be specified separately 
  from the Global directory, useful for operating systems with caching file 
  systems.

 +StateManager config directive.  StateManager specifies how frequently
  Sessions are cleaned up, with 10 (default) meaning that old Sessions
  will be cleaned up 10 times per SessionTimeout period (default 20 minutes).

 +$Application->SessionCount() implemented, non-portable method.
	: returns the number of currently active sessions

 -STOP button fix.  Users may hit STOP button during script 
  execution, and Apache::ASP will cleanup with a routine registered
  in Apache's $r->register_cleanup.  Works well supposedly.

 +PerlScript compatibility work, trying to make ports smoother.
	: Collection emulator, no ->{Count} property
	: $.*(.*)->{Item} parsed automatically, 
	  shedding the ->{Item} for Collection support (? better way ?)
	: No VBScript dates support, just HTTP RFC dates with HTTP::Date
	: Win32::OLE::in not supported, just use "keys %{$Collection}"	

 +./cgi/asp script for testing scripts from the command line
	: will be upgraded to CGI method of doing asp
	: is not "correct" in anyway, so not documented for now
	  but still useful

 +strips DOS carriage returns from scripts automatically, so that
  programs like FrontPage can upload pages to UNIX servers
  without perl choking on the extra \r characters.


=item $VERSION = 0.05; $DATE="10/19/98";

 +Added PERFORMANCE doc, which includes benchmarks  +hints.

 +Better installation warnings and errors for other modules required. 

 -Turned off StatINC in eg/.htaccess, as not everyone installs Devel::Symdump

 -Fixed AUTOLOAD state bug, which wouldn't let you each through state
  objects, like %{$Session}, or each %$Session, (bug introduced in v.04)

 +Parses ASP white space better.  HTML output matches author's intent
  by better dealing with white space surrounding <% perl blocks %>

 -Scalar insertion code <%=$foo%> can now span many lines.

 +Added include.t test script for includes.

 +Script recompiles when included files change.

 +Files can be included in script with 
  SSI <!--#include file="filename"--> syntax, needs to be
  done in ASP module to allow compilation of included code and html 
  into script.  Future chaining with Apache::SSI will allow static 
  html includes, and other SSI directives


=item $VERSION = 0.04; $DATE="10/14/98";

 +Example script eg/cgi.htm demonstrating CGI.pm use for output.

 +Optimized ASP parsing, faster and more legible executing code
	: try 'die();' in code with setting PerlSetVar Debug 2

 +Cleaned up code for running with 'use strict'

 -Fixed directory handle leak on Solaris, from not closing after opendir()

 +StatINC overhaul.  StatINC setting now works as it should, with 
  the caveat that exported functions will not be refreshed.

 +NoState setting optimization, disallows $Application & $Session

 +$Application->*Lock() functions implemented

 -SoftRedirect setting for those who want scripts to keep running
  after a Redirect()

 +SessionSerialize setting to lock session while script is running
	: Microsoft ASP style session locking
	: For a session, scripts execute one at a time 
	: NOT recommended use, please see note.

 -MLDBM can be used for other things without messing up internal use
	: before if it was used with different DB's and serializers,
	  internal state could be lost.

 --State file locking.  Corruption worries, and loss of data no more.

 +CGI header support, developer can use CGI.pm for *output*, or just print()
	: print "Set-Cookie: test=cookie\n", and things will just work
	: use CGI.pm for output
	: utilizes $r->send_cgi_header(), thanks Doug!

 +Improved Cookie implementation, more flexible and complete
	- Domain cookie key now works
	: Expire times now taken from time(), and relative time in sec
	: Request->Cookies() reading more flexible, with wantarray()
	  on hash cookie values, %hash = $Request->Cookie('test');

 -make test module naming correction, was t.pm, now T.pm for Unix

 +POD / README cleanup, formatting and HTML friendly.


=item $VERSION = 0.03; $DATE="09/14/98";

 +Installation 'make test' now works

 +ActiveX objects on Win32 implemented with $Server->CreateObject() 

 +Cookies implemented: $Response->Cookies() & $Request->Cookies()

 -Fixed $Response object API, converting some methods to object members.
  Deprecated methods, but backwards compatible.

 +Improved error messaging, debug output

 +$, influences $Response->Write(@strings) behavior

 +perl print() works, sending output to $Response object

 +$Response->Write() prints scalars, arrays, and hashes.  Before only scalars.

 +Begin implementation of $Server object.

 +Implemented $Response->{Expires} and $Response->{ExpiresAbsolute}

 +Added "PerlSetVar StatINC" config option

 +$0 is aliased to current script filename

 +ASP Objects ($Response, etc.) are set in main package
  Thus notation like $main::Response->Write() can be used anywhere.


=item $VERSION = 0.02; $DATE="07/12/98";

 ++Session Manager, won't break under denial of service attack

 +Fleshed out $Response, $Session objects, almost full implementation.

 +Enormously more documentation.

 -Fixed error handling with Debug = 2.

 -Documentation fixed for pod2man support.  README now more man-like.

 -Stripped \r\n dos characters from installation files

 -755 mode set for session state directory when created

 -Loads Win32/OLE properly, won't break with UNIX


=item $VERSION = 0.01; $DATE="06/26/98";

 Syntax Support
 --------------
 Initial release, could be considered alpha software.
 Allows developers to embed perl in html ASP style.

 <!-- sample here -->
 <html>
 <body>
 <% for(1..10) { %>
 	counting: <%=$_%> <br>
 <% } %>
 </body>
 </html>

 ASP Objects
 -----------
 $Session, $Application, $Response, $Request objects available
 for use in asp pages.

 $Session & $Application data is preserved using SDBM files.

 $Session id's are tracked through the use of cookies.

 Security
 --------
 Timeouts any attempt to use a session id that doesn't already 
 exist.  Should stop hackers, since there is no wire speed guessing
 cookies.

=head1 COPYRIGHT

Copyright (c) 1998-2000, Joshua Chamas, Chamas Enterprises Inc. 

All rights reserved.  This program is free software; you can 
redistribute it and/or modify it under the same terms as Perl itself. 

=cut



