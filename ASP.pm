#!/usr/local/bin/perl -w

# For documentation for this module, please see the end of this file
# or try `perldoc Apache::ASP`
package Apache::ASP;

sub VERSION { .08; }
srand(time()); 

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
use Carp qw(confess);

# use Storable;
# problem with Storable with MLDBM, when referencing empty undefined
# value, hangs, and module reloads.
# $MLDBM::Serializer = "Storable"; # faster than using Data::Dumper
#
$MLDBM::Serializer = "Data::Dumper";

@Apache::ASP::Contacts    = ('modperl@apache.org', 'chamas@alumni.stanford.org');
%Apache::ASP::Compiled    = ();
$Apache::ASP::OLESupport  = 0;
$Apache::ASP::GlobalASA   = 0;
$Apache::ASP::Md5         = new MD5();
@Apache::ASP::Objects     = ('Application', 'Session', 'Response', 'Server', 'Request');
$Apache::ASP::SessionCookieName = 'session-id';

# keep track of included libraries and function codes for StatINC
%Apache::ASP::StatINC     = (); 
%Apache::ASP::Codes       = (); 

# used to keep track of modification time of included files 
%Apache::Includes         = (); 

# X: not thread safe for now since $r changes between handler and register_cleanup
# hash of Apache $r request keys to Apache::ASP values
# hopefully this will work in threaded context
# we need to keep ASP state around for lookup with $r for 
# $r->register_cleanup
$Apache::ASP::Register = undef;
#$Apache::ASP::Filtering = 0;

# only if we support active objects on Win32 do we create
# the server object, which is in charge of object creation
eval 'require("Win32/OLE.pm")';
unless($@) {
    require("Win32/OLE.pm");
    $Apache::ASP::OLESupport = 1;
}

# DEFAULT VALUES
$Apache::ASP::SessionTimeout = 1200;
$Apache::ASP::StateManager   = 10;

sub handler {
    my($package, $r) = @_;
    my $status = 200; # default OK

    # allows it to be called as an object method
    if(ref $package) {
	$r = $package;
    }

    # rarely happens, but just in case
    unless($r && $r->can('filename')) {
	# this could happen with a bad filtering sequence
	warn("no request object ($r:$_[1]) passed to ASP handler");
	return(500);
    }

    #X: fix the error checking please
    return(404) unless (-e $r->filename());

    # ASP object creation, a lot goes on in there!
    my($self) = new($r);

    $self->Debug('ASP object created', $self) if $self->{debug};    

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
    $self->DESTROY() if($self->{filter});

    $status;
}

sub new {
    my($r) = @_;

    # like cgi, operate in the scripts directory
    my $dirname = File::Basename::dirname($r->filename());
    chdir($dirname);
    my($basename) = File::Basename::basename($r->filename());

    # session timeout in seconds since that is what we work with internally
    my $session_timeout = $r->dir_config('SessionTimeout') ? 
	$r->dir_config('SessionTimeout') * 60 : $Apache::ASP::SessionTimeout;

    # what percent of the session_timeout's time do we garbage collect
    # state files and run programs like Session_OnEnd and Application_OnEnd
    my $state_manager = $r->dir_config('StateManager') 
	|| $Apache::ASP::StateManager;
    
    # global is the default for the state dir and also 
    # a default lib path for perl, as well as where global.asa
    # can be found
    my $global = $r->dir_config('Global') || '.';
    $global = AbsPath($global, $dirname);
    # state is the path where state files are stored, like $Session,
    # $Application, etc.
    my $state_dir = $r->dir_config('StateDir') || "$global/.state";

    # asp object is handy for passing state around
    my $self = bless { 
	app_start      => 0,  # set this if the application is starting

	'basename'     => $basename,

	# buffer output on by default
	buffering_on   => (defined $r->dir_config('BufferingOn')) ? $r->dir_config('BufferingOn') : 1, 
	    
	# if this is set we are parsing ourself through cgi
	cgi_do_self        => $r->dir_config('CgiDoSelf') || 0, # parse self

	# this is the server path that the client responds to 
	cookie_path    => $r->dir_config('CookiePath') || '/',
	
	# set for when we are executing from command line
	command_line   => $r->dir_config('CommandLine'),

	# these are set by the Compile routine
	compile_error  => undef, 
	
	debug          => $r->dir_config('Debug') || 0,  # debug level
	'dirname'      => $dirname,
	errors         => 0,
	errors_output  => [],
	filehandle     => undef,
	filename       => $r->filename(),
	filter         => 0,
	id             => '', # parsed version of filename
	
	# where all the state and config files lie
	global         => $global,
	
	# refresh group by some increment smaller than session timeout
	# to withstand DoS, bruteforce guessing attacks
	# defaults to checking the group once every 2 minutes
	group_refresh  => int($session_timeout / $state_manager),
	groups_refresh => int($session_timeout / $state_manager),

	# assume we already chdir'd to where the file is
	mtime          => stat($basename)->mtime,  # better than -M
		
	no_cache       => $r->dir_config(NoCache),
	no_headers     => $r->dir_config(NoHeaders) || 0,
	no_session     => ((defined $r->dir_config('AllowSessionState')) ? (! $r->dir_config('AllowSessionState')) : 0),

	# set this if you don't want an Application or Session object
	# available to your scripts
	no_state       => $r->dir_config('NoState'),
	
	# default 1, should we parse out pod style commenting ?
	pod_comments   => defined($r->dir_config('PodComments')) ? $r->dir_config('PodComments') : 1, 

	r              => $r, # apache request object 
	remote_ip      => $r->connection()->remote_ip(),
	session_timeout => $session_timeout,
	session_serialize => $r->dir_config('SessionSerialize'),
	
	soft_redirect  => $r->dir_config('SoftRedirect'),
	stat_inc       => $r->dir_config('StatINC'),    

	state_dir      => $state_dir,
	state_manager  => $state_manager,

	# special objects for ASP app
	Application    => '',
	GlobalASA      => '',
	Internal       => '',
	Request        => '',
	Response       => '',
	Session        => '',
	Server         => '',
    };
    
    $self->Debug("STARTING ASP HANDLER for file $self->{filename}")
	if $self->{debug};
    
    if($self->{no_cache}) {
	# this way subsequent recompiles overwrite each other
	$self->{id} = "NoCache";
    } else {
	$self->{id} = $self->{filename};
	$self->{id} =~ s/\W/_/gso;
    }

    # filtering support
    my $filter_config = $r->dir_config('Filter') || $Apache::ASP::Filter;
    if($filter_config && ($filter_config !~ /off/io)) {
        if($r->can('filter_input') && $r->can('get_handlers')) {
	    $self->{filter} = 1;
#	    $Apache::ASP::Filtering = 1;
	    #X: do something with the return code, can't now because
	    # apache constants aren't working on my win32
	    my($fh, $rc) = $r->filter_input();
	    $self->{filehandle} = $fh;
	} else {
	    if(! $r->can('get_handlers')) {
		$self->Error("You need at least mod_perl 1.16 to use SSI filtering");
	    } else {
		$self->Error("Apache::Filter was not loaded correctly for using SSI filtering");
	    }
	}
    }

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
    
    # register cleanup before the state files get set in InitObjects
    # this way DESTROY gets called every time this script is done
    # we must cache $self for lookups later
    $Apache::ASP::Register = $self;
    $r->register_cleanup(\&Apache::ASP::RegisterCleanup);

    # initialize the big ASP objects now
    $self->InitObjects();

    $self;
}

# registered in new() so that is called every end of connection
sub RegisterCleanup {
    my $asp = $Apache::ASP::Register;
    $asp->DESTROY() if $asp;
}
    
# called upon every end of connection by RegisterCleanup
sub DESTROY {
    my($self) = @_;
    my($k, $v);
    
    return if $self->{destroyed};
    $self->Debug("destroying", {asp=>$self});
    $self->{destroyed} = 1;
#    $Apache::ASP::Filtering = 0;
    
    # we try to clean up our own group each time, since this way the 
    # cleanup load should be spread out amongst processes.  If the
    # server is really busy, CleanupGroups() won't get to do anything,
    # but if the server is slow, CleanupGroups is essential so that 
    # some Sessions actually get ended, and Session_OnEnd gets called
    $self->CleanupGroups();
    $self->CleanupGroup();  

    # free file handles here.  mod_perl tends to be pretty clingy
    # to memory
    no strict 'refs';
    for('Application', 'Internal', 'Session') {
	# all this stuff in here is very necessary for total cleanup
	# the DESTROY is the most important, as we need to explicitly free
	# state objects, just in case anyone else is keeping references to them
	# But the destroy won't work without first untieing, go figure
	my $tied = tied %{$self->{$_}};
	next unless $tied;
	untie %{$self->{$_}};
	$tied->DESTROY(); # call explicit DESTROY
	$self->{$_} = undef;
    }

    $self->Debug("END ASP HANDLER") if $self->{debug};
    while(($k, $v) = each %{$self}) {
	next if ($k eq 'r');
	undef $self->{$k};
    }

    1;
}

sub InitObjects {
    my($self) = @_;

    # always create these
    $self->{GlobalASA} = &Apache::ASP::GlobalASA::new($self);
    $self->{Response}  = &Apache::ASP::Response::new($self);
    $self->{Request}   = &Apache::ASP::Request::new($self);
    $self->{Server}    = &Apache::ASP::Server::new($self);

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
	$self->{Internal} = bless \%Internal, 'Apache::ASP::State';
	
	# Session state is dependent on internal state
	$self->{Session} = &Apache::ASP::Session::new($self);    	
	if($self->{Session}->Started) {
	    # we only want one process purging at a time
	    $self->{Internal}->LOCK();
	    if(($self->{Internal}{LastSessionTimeout} || 0) < time()) {
		$self->{Session}->Refresh();
		$self->{Internal}->UNLOCK();
		$self->CleanupGroups('PURGE');
		$self->{GlobalASA}->ApplicationOnEnd();
		$self->{GlobalASA}->ApplicationOnStart();
	    } 
	    $self->{Internal}->UNLOCK();
	    $self->{GlobalASA}->SessionOnStart();
	}
	$self->{Session}->Refresh();
    } else {
	$self->{debug} && $self->Debug("no sessions allowed config");
    }
    
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

    # support for includes, changes to included files
    # cause script to recompile
    my $includes;
    if($includes = $Apache::ASP::Includes{$self->{id}}) { 
	# initial test for performance?
	while(my($k, $v) = each %$includes) {
	    if(stat($k)->mtime > $v) {
		return 1;
	    }
	}
    }

    # always recompile if we are not supposed to cache
    if($self->{no_cache}) {
	return 1;
    }

    my $last_update = $Apache::ASP::Compiled{$self->{id}}->{mtime} || 0;
    if($self->{filter}) {
	$self->{r}->changed_since($last_update);
    } else {
	# we only get here if we have a chance of caching and all
	# our dependent components have not changed
	($self->{mtime} > $last_update) ? 1 : 0;
    }
}        

sub Parse {
    my($self) = @_;
    my($script, $text, $perl);

    # get script data, from varied data sources
    my($data, $filehandle);
    if($filehandle = $self->{filehandle}) {
	local $/ = undef;
	$data = <$filehandle>;
#	$self->Debug("filehandle $filehandle data $data");
    } else {
	$data = $self->ReadFile($self->{'basename'});
    }

    if($self->{cgi_do_self}) {
	$data =~ s/^(.*?)__END__//gso;
    }

    # do includes as early as possible !! so included text get's done too
    # this section is for file includes, we do this here instead of ssi
    # so it can be parsed and compiled with the script
    my $munge = $data;
    while($munge =~ s/^(.*?)\<!--\#include\s+file\s*\=\s*\"([^\"]*)\"\s*--\>(.*)$/$3/so) {
	my $file = $2;
	my $included = 0;
	# we look for the include file in both the current directory and the 
	# global directory
	for $include ($file, "$self->{global}/$file") {
	    unless(-e $include) {
		next;
	    }
	    $included = 1;
	    $Apache::ASP::Includes{$self->{id}}{$include} = stat($include)->mtime;
	    my $text = $self->ReadFile($include);
	    $data =~ s/\<!--\#include\s+file\s*\=\s*\"$file\"\s*--\>/$text/sg;
	}
	$included || $self->Error("include file with name $file does not exist");
    }
    
    # strip carriage returns; do this as early as possible
    my $CRLF = "\015\012";
    $data =~ s/$CRLF/\n/sgo;

    if($self->{pod_comments}) {
	$data =~ s/\n\=pod\n.*?\n\=cut\n//gso; # support pod style commenting
    }

    # there should only be one of these, <%@ LANGUAGE="PerlScript" %>, rip it out
    $data =~ s/^\s*\<\%\s*\@([^\n]*?)\%\>//so; # only take out the first one 
    $data .= "\n<%;%>\n"; # always end with some perl code for parsing.
    my(@out, $perl_block, $last_perl_block);
    while($data =~ s/^(.*?)\<\%(?:\s*\n)?(.*?)\s*\%\>//so) {
	($text, $perl) = ($1,$2);
	$perl =~ s/^\s+$//gso;
	$text =~ s/^\s$//gso;
	$perl_block = ($perl =~ /^\s*\=(.*)$/so) ? 0 : 1;

	# with some extra text parsing, we remove asp formatting from
	# influencing the generated html formatting, in particular
	# dealing with perl blocks and new lines
	if($text) {
	    $text =~ s/\\/\\\\/gso;
	    $text =~ s/\'/\\\'/gso;

	    # remove the tail white space from the text before
	    # a perl block, as long as there is a newline there
	    if($perl_block) {
		$text =~ s/\n\s*?$/\n/so;
	    }

	    # remove the head white space from the text after a perl block
	    # as long as there is a newline there
	    if($last_perl_block) {
		$text =~ s/^\s*?\n//so;
		$last_perl_block = 0;
	    }

	    push(@out, "\'".$text."\'")
	}

	if($perl) {
	    # X:
	    # take out, since this might get someone in trouble
	    # should work on the objects for porting compatibility
	    # like a Collections class.
	    #
	    # PerlScript compatibility
	    if($perl =~ s/(\$.*?\(.*?\))\-\>\{item\}/$1/isgo) {
		$self->Debug('parsing out ->{item} for PerlScript compatibility');
	    }
	    
	    if(! $perl_block) {
		# we have a scalar assignment here
		push(@out, '('.$1.')');
	    } else {
		$last_perl_block = 1;
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
	    $file = "$dir/$file";
	} else {
	    $file;
	}
    }
}       
    
sub Compile {
    my($self, $script, $id) = @_;
    my($package) = $id ? $id : $self->{id};
    
    $self->Debug("compiling", {'package'=> $package });
    undef &{"Apache::ASP::Compiles::" . $package . "::handler"};

    my($eval) = 
	join("\n", 
	     "package Apache::ASP::Compiles::" . $package . ";" ,
	     'no strict;', 
	     "use vars qw(\$".join(" \$",@Apache::ASP::Objects).');',
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
    if($@) {
	$self->Error($@);
	$self->{compile_error} .= "\n$@\n";
    } 

    # more errors could happen with use strict, so test for them here
    if($self->{errors}) {
	# make sure there isn't a trace of this compile left after an error
	undef &{"Apache::ASP::Compiles::" . $package . "::handler"};
    } else {
	$Apache::ASP::Compiled{$package}->{mtime}  = $self->{mtime};
    }
    $Apache::ASP::Compiled{$package}->{output} = $eval;	
    
    (! $self->{errors});
}

sub Execute {
    my($self, $id, $routine) = @_;
    
    return if $self->{errors};

    # return if the response has been ended already, this could happen
    # if someone ends in Session_OnStart for example, which is run as
    # a separate script
    return if $self->{Response}{Ended};

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
	    $$init_var = $self->{$object};
	}
    }

    # set printing to Response object
    tie *RESPONSE, 'Apache::ASP::Response', $self->{Response};
    select(RESPONSE);
    $| = 1; # flush immediately

    # set reading from Request Object
    #   untie *STDIN;
    # tie *STDIN, 'Apache::ASP::Request', $self->{Request};

    # run the script now, then check for errors
    eval ' &{$handler}($self, $routine) ';  
    if($@ && $@ !~ /Apache\:\:exit/) { $self->Error($@); } 
    
    # so we don't interfere with the printing mechanism of 
    # other perl-handlers
#    untie *STDIN;
    select(STDOUT); # filtering makes us keep this here instead of DESTROY

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

    my($state, $temp_state, $total);
    my $asp = $self; # bad hack for some moved around code
    my $id = $self->{Session}->SessionID();
    my $deleted = 0;
    $force ||= 0;

    if($group_id) {
	# use a temp state object
	$state = &Apache::ASP::State::new($asp, $group_id);
    } else {
	$state = $self->{Session}{_STATE};
	$group_id = $state->GroupId();
    }
    
    # we must have a group id to work with
    $asp->Error("no group id") unless $group_id;
    $group_id = "GroupId" . $group_id;

    # cleanup timed out sessions, from current group
    my($group_check) = $asp->{Internal}{$group_id} || 0;
    return unless ($force || ($group_check < time()));

    $asp->Debug("group check $group_id");
    # set the next group_check
    $asp->{Internal}{$group_id} = time() + $asp->{group_refresh};
    
    my $ids = $state->GroupMembers();
    my @ids = @{$ids};
    $total = @ids;
    for(@ids) {
	my $timeout = $asp->{Internal}{$_}{timeout} || 0;
	if($id eq $_) {
	    $asp->Debug("skipping delete self", {id => $id});
	    next;
	}
	
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
	
	# Run SessionOnEnd
	$asp->{GlobalASA}->SessionOnEnd($_);
	
	# set up state
	my($member_state) = Apache::ASP::State::new($asp, $_);
	if(my $count = $member_state->Delete()) {
	    $asp->Debug("deleting session", {
		session_id => $_, 
		files_deleted => $count,
	    });
	    $deleted++;
	} else {
	    $asp->Error("can't delete session id: $_");
	    next;
	}
	delete $asp->{Internal}{$_};
    }
    
    # if the directory is now empty, remove it
    if($deleted == $total) {
	$state->DeleteGroupId();
    }

    $deleted;
}

sub CleanupGroups {
    my($self, $force) = @_;
    return unless $self->{Session};

    my $cleanup = 0;
    my $state_dir = $self->{state_dir};
    $force ||= 0;

    $self->Debug("forcing groups cleanup") if $force;

    # each apache process has an internal time in which it 
    # did its last check, once we have passed that, we check
    # $Internal for the last time the check was done.  We
    # break it up in this way so that locking on $Internal
    # does not become another bottleneck for scripts
    if(($Apache::ASP::CleanupGroups{$state_dir} || 0) < time()) {
	$Apache::ASP::CleanupGroups{$state_dir} = time() + $self->{groups_refresh};
	$self->{Internal}->LOCK;
	if($force || ($self->{Internal}{CleanupGroups} < time())) {
	    $self->{Internal}{CleanupGroups} = time() + $self->{groups_refresh};
	    $cleanup = 1;
	}
	$self->{Internal}->UNLOCK;
    }
    return unless $cleanup;

    my $groups = $self->{Session}{_SELF}{'state'}->DefaultGroups();
    my($sum_active, $sum_deleted);
    for(@{$groups}) {	
	$sum_deleted = $self->CleanupGroup($_, $force);
    }
    $self->Debug("cleanup groups", { deleted => $sum_deleted });	

    $sum_deleted;
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
	unless($self->{command_line}) {
	    $_ = $self->Escape($_);
	}
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
	
    my($debug) = $msg;
    if(ref $data) {
	$debug .= "... ";
	for(sort keys %{$data}) {
	    $data->{$_} ||= '';
	    $debug .= "$_: $data->{$_}; ";
	}
    }
    $self->Log("[debug] [$$] $debug");
    push(@{$self->{debugs_output}}, $debug);
    
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
	for(@parts) {	
	    my($name, $value) = split(/\=/, $_, 2);
	    if($name eq $Apache::ASP::SessionCookieName) {
		$id = $value;
		last;
	    }
	}
	$self->Debug("SessionCookie", {id => $id}) if $id;
    }

    $id;
}

sub Secret {
    my($self) = @_;

    my $md5 = $Apache::ASP::Md5;
    $md5->reset;
    $md5->add($self . $self->{remote_ip} . rand() . time() . $md5);
    
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

# GlobalASA Object
# global.asa processes, whether or not there is a global.asa file.
# if there is not one, the code is left blank, and empty routines
# are filled in
package Apache::ASP::GlobalASA;
use File::stat;

# these define the default routines that get parsed out of the 
# GLOBAL.ASA file
@Apache::ASP::GlobalASA::Routines = 
    (
     "Application_OnStart", 
     "Application_OnEnd", 
     "Session_OnStart", 
     "Session_OnEnd"
     );

sub new {
    my $asp = shift;
    $asp || die("no asp passed to GlobalASA");

    my $filename = "$asp->{global}/global.asa";
    my $exists = (-e $filename);
    my $id = $filename;
    $id =~ s/\W/_/isg;

    my $self = bless { 
	asp => $asp,
	'exists' => $exists,
	filename => $filename,
	id => $id,
	mtime => $exists ? stat($filename)->mtime : 0,
    };

    my $compiled = $Apache::ASP::Compiled{$self->{id}};
    unless($compiled) {
	$Apache::ASP::Compiled{$self->{id}} = 
	    $compiled = { mtime => 0, 'exists' => 0 };
    }

    my $changed = 0;
    if(!($exists) && $compiled && $compiled->{'exists'}) {
	# if the global.asa disappeared
	$changed = 1;
    } elsif($exists && $compiled && ! $compiled->{'exists'}) {
	# if global.asa reappeared
	$changed = 1;
    } else {
	if($self->{mtime} >= $compiled->{mtime}) {
	    # if the modification time is greater than the compile time
	    $changed = 1;
	} 
    }
    return($self) unless $changed;

    my $code = $exists ? $asp->ReadFile($filename) : "";
    $code =~ s/\<\/?script?.*?\>/\#script tag removed here/igs;
    
    # if we have success compiling, then update the compile time
    if($asp->Compile($code, $id)) {
	$compiled->{mtime} = time();

	# remember whether the file really exists
	$compiled->{'exists'} = $exists;

	# we cache whether the code was compiled so we can do quick
	# lookups before executing it
	my $routines = {};
	local *stash = *{"Apache::ASP::Compiles::$self->{id}::"};
	for(@Apache::ASP::GlobalASA::Routines) {
	    if($stash{$_}) {
		$routines->{$_} = 1;
	    }
	}
	$compiled->{'routines'} = $routines;
	$asp->Debug('global.asa routines', $routines);
    }

    $self;
}

sub IsCompiled {
    my($self, $routine) = @_;
    my $compiled = $Apache::ASP::Compiled{$self->{id}}->{'routines'};
    $compiled->{$routine};
}

sub Execute {
    my($self, $routine) = @_;
    my $asp = $self->{asp};
    if($self->IsCompiled($routine)) {
	$asp->Execute($self->{id}, $routine);
    } 
}

sub SessionOnStart {
    my($self) = @_;
    my $asp = $self->{asp};
    my $zero_sessions = 0;

    $asp->{Internal}{_LOCK} = 1;
    my $session_count = $asp->{Internal}{SessionCount} || 0;
    if($session_count <= 0) {
	$asp->{Internal}{SessionCount} = 1;	
	$zero_sessions = 1;
    } else {
	$asp->{Internal}{SessionCount} = $session_count + 1;
    }
    $asp->{Internal}{_LOCK} = 0;

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

    $asp->{Internal}{SessionCount}--;
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
    my($self) = @_;
    $self->{asp}->Debug("Application_OnStart");
    %{$self->{asp}{Application}} = (); # clear application now
    $self->Execute("Application_OnStart");
}

sub ApplicationOnEnd {
    my($self) = @_;
    $self->{asp}->Debug("Application_OnEnd");
    $self->Execute("Application_OnEnd");
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
    my $r = $_[0]->{r};
    my(%query, %form, %cookies, %env); 
    my $form = {};

    my($self) = bless { 
	asp => $_[0],
	content => '',
	Cookies => '',
	Form => '',
	QueryString => '',
	ServerVariables => '',
    };
    
    # set up the environment, including authentication info
    %env = $r->cgi_env();
    my $c = $r->connection;
    my $user;
    if(defined($c->user)) {
	#X: this needs to be extended to support Digest authentication
	$env{AUTH_TYPE} = $c->auth_type;
	$env{AUTH_USER} = $c->user;
	$env{REMOTE_USER} = $c->user;
	$env{AUTH_PASSWD} = $r->get_basic_auth_pw();
    }
    $self->{'ServerVariables'} = \%env;

    # assign no matter what so Form is always defined
    if(($r->method() || '') eq "POST") {	
	if($ENV{CONTENT_TYPE}=~ m|^multipart/form-data|) {
	    eval { require 'CGI.pm' };
	    if($@) { 
		$self->{asp}->Error("can't use file upload without CGI.pm");
	    } else {		
		my $q = new CGI;
		$self->{asp}->Debug("reading file upload");
		for(my @names = $q->param) {
		    if(*{$q->param($_)}) {
			$form{$_} = *{$q->param($_)};
		    } else {
			$form{$_} = $q->param($_);		    
		    }
		}
		$form = \%form;
	    }
	} else {
	    $self->{content} = $r->content();
	    $form = $self->ParseParams(\$self->{content});
	    $ENV{CONTENT_LENGTH} = 0;
	}
    } 

    $self->{'Form'} = bless $form, 'Apache::ASP::Collection';
    %query = $r->args();
    $self->{'QueryString'} = bless \%query, 'Apache::ASP::Collection';

    # X: We would like full CGI use with CGI reading input too!

    # do cookies now
    my @parts = split(/;\s*/, ($r->header_in("Cookie") || ''));
    for(@parts) {	
	my($name, $value) = split(/\=/, $_, 2);
	$name = $self->Unescape($name);

	next if ($name eq $Apache::ASP::SessionCookieName);
	next if $cookies{$name}; # skip dup's

	$cookies{$name} = ($value =~ /\=/) ? 
	    $self->ParseParams($value) : $self->Unescape($value);
    }
    $self->{Cookies} = bless \%cookies, 'Apache::ASP::Collection';

    $self;
}

# just returns itself
sub TIEHANDLE { $_[1] };

sub READ {
    my($self, $buf, $len) = @_;
    $buf ||= "";
    $buf .= substr($self->{content}, 0, $len);
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
	my $value = $self->{$AUTOLOAD}{$index};	
	if(wantarray) {
	    (ref($value) =~ /ARRAY/o) ? @{$value} : $value;
	} else {
	    (ref($value) =~ /ARRAY/o) ? $value->[0] : $value;
	}
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
    my($self, $string) = @_;

    ($string = $$string) if ref($string); ## faster if we pass a ref for a big string
    my @params = map { $self->Unescape($_) } split /[=&]/, $string, -1;
    my %params;

    # we have to iterate through the params here to collect multiple values for 
    # the same param, say from a multiple select statement
    while(@params) {
	my($key, $value) = (shift(@params), shift(@params));
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
    my($self, $todecode) = @_;
    $todecode =~ tr/+/ /;       # pluses become spaces
    $todecode =~ s/%([0-9a-fA-F]{2})/pack("c",hex($1))/ge;
    return $todecode;
}

1;

# Response Object
package Apache::ASP::Response;
@ISA = qw(Apache::ASP::Collection);
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
    my($asp) = @_;
    my $r = $asp->{r};
    $, ||= '';

    return bless {
	asp => $asp,
	buffer => '',
	# internal extension allowing various scripts like Session_OnStart
	# to end the same response
	Ended => 0, 
	Cookies => bless({}, 'Apache::ASP::Collection'),
	ContentType => 'text/html',
	header_buffer => '', 
	header_done => 0,
	Buffer => $asp->{buffering_on},
	r => $r,
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

sub AddHeader { 
    my($self, $name, $value) = @_;   
    if($name =~ /^set\-cookie$/io) {
	$self->{r}->cgi_header_out($name, $value);
    } else {
	$self->{r}->header_out($name, $value);
    }
}   

sub AppendToLog { $_[0]->{asp}->Log($_[1]); }
*BinaryWrite = *Write; # someone needs to explain the difference to me
sub Clear { $_[0]->{buffer} = ''; }

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
    $self->{Ended} = 1;
    die('Apache::exit');
}

sub Flush {
    my($self) = @_;

    # if this is the first writing from the page, flush a newline, to 
    # get the headers out properly
    if(! $self->{header_done}) {
	$self->{header_done} = 1;
	unless($self->{asp}->{no_headers}) {
	    $self->SendHeaders();
	}
    }

#    $self->{asp}->Debug("flushing $self->{buffer}");
    if($self->{asp}{filter}) {
	print STDOUT $self->{buffer};
    } else {
	$self->{r}->print($self->{buffer});	
    }
    $self->{buffer} = '';

    1;
}

# use the apache internal redirect?  Thought that would be counter
# to portability, but is still something to consider
sub Redirect {
    my($self, $location) = @_;

    $self->Clear();
    $self->{asp}->Debug('redirect called', {location=>$location});
    $self->{r}->header_out('Location', $location);
    $self->{Status} = 302;
    $self->Flush();

    # if we have soft redirects, keep processing page after redirect
    unless($self->{asp}{soft_redirect}) {
	$self->End(); 
    } else {
	$self->{asp}->Debug("redirect is soft");
    }

    1;
}

sub SendHeaders {
    my($self) = @_;
    my $r = $self->{r};

    $self->{asp}->Debug("building cgi headers");
    if(defined $self->{Status}) {
	$r->status($self->{Status});
	$self->{asp}->Debug("custom status $self->{Status}");
    }
    $r->content_type($self->{ContentType}); # add content-type
    $self->AddCookieHeaders();     # do cookies
    
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
    
    # don't send headers with filtering, since filter will do this for
    # all the modules once
    # doug sanctioned this one
    my $sent = $self->{r}->header_out("Content-type");
    unless($sent) {
	# if filtering, we don't send out a header from ASP
	# this means that Filtered scripts can use CGI headers
	# we order the test this way in case Ken comes on
	# board with setting header_out, in which case the test 
	# will fail early       
	unless($self->{asp}{filter}) {
	    $self->{asp}->Debug("sending cgi headers");
	    if($self->{header_buffer}) {
		# we have taken in cgi headers
		$r->send_cgi_header($self->{header_buffer} . "\n");
		$self->{header_buffer} = '';
	    } else {	
		$r->send_http_header();
	    }
	} 
    }

    1;
}

# do cookies, try our best to emulate cookie collections
sub AddCookieHeaders {
    my($self) = @_;
    my($cookies) = $self->{'Cookies'};
    my $cookie;

    my $cookie_name;
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

sub Write {
    my($self, @send) = @_;
    return unless defined($send[0]);

    # work on the headers while the header hasn't been done
    # and while we don't have anything in the buffer yet
    if(! $self->{header_done} && ! $self->{buffer}) {
	# -1 to catch the null at the end maybe
	my @headers = split(/\n/, $send[0], -1); 

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
	
	# if we found some headers, pop the first entry off 
	# what to @send, and continue
	if($self->{header_buffer}) {
	    if(defined $headers[0]) {
		$send[0] = join("\n", @headers);
	    } else {
		shift @send;
	    }
	}
    }

    # add @send to buffer
    $self->{buffer} .= join($,, @send);

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
@ISA = qw(Apache::ASP::Collection);
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

sub SessionCount {
    my $self = shift;
    $self->{_SELF}{asp}{Internal}{SessionCount};
}
    
1;

# Session Object
package Apache::ASP::Session;
@ISA = qw(Apache::ASP::Collection);
use Apache;

# allow to pass in id so we can cleanup other sessions with 
# the session manager
sub new {
    my($asp, $id) = @_;
    my($state, %self, $started);

    # if we are passing in the id, then we are doing a 
    # quick session lookup and can bypass the normal checks
    # this is useful for the session manager and such
    if($id) {
	$state = Apache::ASP::State::new($asp, $id);
	$state->Set() || $asp->Error("session state get failed");
	tie %self, 'Apache::ASP::Session', 
	{
	    state=>$state, 
	    asp=>$asp, 
	    id=>$id,
	};
	return bless \%self;
    }

    if($id = $asp->SessionId()) {
	$state = Apache::ASP::State::new($asp, $id);
	$state->UserLock() if $asp->{session_serialize};
	$asp->Debug("new session state $state");

	my $internal;
	if($internal = $asp->{Internal}{$id}) {
	    # user is authentic, since the id is in our internal hash
	    if($internal->{timeout} > time()) {
		# session not expired
		$asp->Debug("session not expired",{'time'=>time(), timeout=>$internal->{timeout}});
		unless($state->Get('NO_ERROR')) {
		    $asp->Log("session not timed out, but we can't tie to old session! ".
			      "report this as an error with the relevant log information for this ".
			      "session.  We repair the session by default so the user won't notice."
			      );
		    unless($state->Set()) {
			$asp->Error("failed to re-initialize session");
		    }
		}
		$started = 0;
	    } else {
		# expired, get & reset
		$asp->Debug("session timed out, clearing");
		undef $state;
		$asp->{GlobalASA}->SessionOnEnd($id);
		
		# we need to create a new state now after the clobbering
		# with SessionOnEnd
		$state = Apache::ASP::State::new($asp, $id);
		$state->UserLock() if $asp->{session_serialize};		
		$state->Init() || $asp->Error("session state init failed");
		$asp->{Internal}{$id} = {};
		$started = 1;
	    }
	} else {
	    # never seen before, maybe session garbage collected already

	    # slow them down so provable security
	    # if we had wire speed authentication, we'd
	    # have a real security issue, otherwise, the md5
	    # hash session key is 2^128 in size, so would 
	    # take arguably too long for someone to try all the 
	    # sessions before they get garbage collected
	    sleep(1); 
	    $state->Init() || $asp->Error("session state init failed");
	    $asp->{Internal}{$id} = {};

	    # wish we could do more 
	    # but proxying + nat prevents us from securing via ip address
	    $started = 1;
	}
    } else {
	# give user new session id, we must lock this portion to avoid
	# concurrent identical session key creation, this is the 
	# only critical part of the session manager
	$asp->{Internal}{_LOCK} = 1;
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
	
	$asp->{Internal}{$id} = {};
	$asp->{Internal}{_LOCK} = 0;
	$asp->Debug("new session id $id");
	$asp->SessionId($id);
	$state = &Apache::ASP::State::new($asp, $id);
	$state->Set() || $asp->Error("session state set failed");
	$started = 1;
    }

    if(! $state) {
	$asp->Error("can't get state for id $id");
	return;
    }

    tie %self, 'Apache::ASP::Session', 
    {
	state=>$state, 
	asp=>$asp, 
	id=>$id,
	started=>$started,
    };
    $asp->Debug("tieing session", \%self);

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

    if($index eq '_SELF') {
	$self;
    } elsif($index eq '_STATE') {
	$self->{state};
    } else {
	$self->{state}->FETCH($index);
    }
}

sub STORE {
    my($self, $index, $value) = @_;
    $self->{state}->STORE($index, $value);
}	

sub SessionID {
    my($self) = @_;
    $self->{_SELF}{id};
}

sub Timeout {
    my($self, $minutes) = @_;
    $self = $self->{_SELF};

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
    my($self) = @_;
    $self->Timeout(-1);
#    %{$self} = ();
}

sub TTL {
    my($self) = @_;
    $self = $self->{_SELF};
    # time to live is current timeout - time... positive means
    # session is still active, returns ttl in seconds
    my $timeout = $self->{asp}{Internal}{$self->{id}}{timeout};
    my $ttl = $timeout - time();
}

sub Refresh {
    my($self) = @_;
    $self = $self->{_SELF};

    my $asp   = $self->{asp};
    my $id    = $self->{id};
    my $idata = $asp->{Internal}{$id};
    my $internal = $asp->{Internal};

    my $refresh_timeout = $idata->{refresh_timeout};
    $refresh_timeout ||= $asp->{session_timeout};
    my $timeout = time() + $refresh_timeout;
    $idata->{timeout} = $timeout;

    # we lock it down here to avoid relocking for each write
    # LastSessionTimeout is used to help with Application global.asa events
    $internal->LOCK();
    $internal->{'LastSessionTimeout'} = $timeout;
    $internal->{$id} = $idata;	
    $internal->UNLOCK();

    1;
}

sub Started {
    my($self) = @_;
    $self->{_SELF}{started};
}

1;

package Apache::ASP::State;
use Fcntl qw(:flock O_RDWR O_CREAT);
$Apache::ASP::State::DefaultGroupIdLength = 2;

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

    my $state_dir = "$asp->{state_dir}";
    my $group_dir = "$state_dir/$group";
    my $lock_file = "$group_dir/$id.lock";

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
	open_lock => 0,
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
    # we skip this for $group_id eq $id since then this is 
    # just a place holder empty state object used 
    # for information purposes only
    $self->OpenLock() unless ($group eq $id);

    if($permissions) {
	$self->Do($permissions);
    }

    $self;
}

sub Get {
    shift->Do(O_RDWR, @_);
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
    my @temp = ($MLDBM::UseDB, $MLDBM::Serializer);
    $MLDBM::UseDB = "SDBM_File";
    $MLDBM::Serializer = 'Data::Dumper';
    $self->{dbm} = &MLDBM::TIEHASH('MLDBM', $self->{file}, $permissions, 0644);
    ($MLDBM::UseDB, $MLDBM::Serializer) = @temp;    

    if($self->{dbm}) {
	# used to have locking code here
    } else {
	unless($no_error) {
	    $self->{asp}->Error("Can't tie to file $self->{file}!! \n".
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
	    $self->{asp}->Error("can't unlink state file $unlink_file: $!"); 
	    return;
	}
    }

    $count;
}

sub DeleteGroupId {
    my($self) = @_; 
  
    if(-d $self->{group_dir}) {
	if(rmdir($self->{group_dir})) {
	    $self->{asp}->Debug("deleting group dir ". $self->GroupId());
	} else {
	    $self->{asp}->Log("cannot delete group dir $self->{group_dir}");
	}
    }
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

sub DefaultGroups {
    my($self) = @_;
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
    untie $self->{dbm} if $self->{dbm};
    $self->{dbm} = undef;
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
	$value = $self->{dbm}->$AUTOLOAD(@_);
	$self->UnLock();
    }

    $value;
}

sub TIEHASH {
    my($type) = shift;

    # dual tie contructor, if we receive a State object to tie
    # then just return it, otherwise construct a new object
    # before tieing
    if((ref $_[0]) =~ /State/) {
	$_[0];
    } else {	
	bless &new(@_), $type;
    }
}

sub FETCH {
    my($self, $index) = @_;
    my $value;

    if($index eq '_FILE') {
	$value = $self->{file};
    } elsif($index eq '_SELF') {
	$value = $self;
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

sub LOCK { shift->{_SELF}->UserLock(); }
sub UNLOCK { shift->{_SELF}->UserUnLock(); }

# the +> mode open a read/write w/clobber file handle.
# the clobber is useful, since we don't have to create
# the lock file first
sub OpenLock {
    my($self) = @_;
    return if $self->{open_lock};
    $self->{open_lock} = 1;
    my $mode = (-e $self->{lock_file}) ? "+<" : "+>"; 
#    $self->{asp}->Debug("opening lock file $self->{lock_file}");
    open($self->{lock_file_fh}, $mode . $self->{lock_file}) 
	|| $self->{asp}->Error("Can't open $self->{lock_file}: $!");
}

sub CloseLock { 
    my($self) = @_;
    return if ($self->{open_lock} == 0);
    $self->{open_lock} = 0;
    close($_[0]->{lock_file_fh})
	|| $self->{asp}->Error("Can't close $self->{lock_file}: $!");
}

sub ReadLock {
    my($self) = @_;
    no strict 'refs';
    my $file = $self->{lock_file_fh};

    if($self->{locked}) {
	$self->{asp}->Debug("already read locked $file");
	1;
    } else {
	$self->{locked} = 1;
	(-e $self->{lock_file})
	    || $self->{asp}->Error("$self->{lock_file} does not exists");
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
	# locks only work when they were locked before
	# we started erroring, because file locking will
	# will hang a system if locking doesn't work properly
	$self->{locked} = 0;
	unless(flock($file, ($UNLOCK || LOCK_UN))) {
	    # we try a flock work around here for QNX
	    my $err = $!;
	    local $^W = 0;
	    eval { $UNLOCK ||=&Fcntl::F_UNLCK; };
	    if($UNLOCK) {
		unless(flock($file, $UNLOCK)) {
		    $self->{asp}->Error("Can't unlock $file even with backup flock: $err, $!");
		}		
	    } else {
		$self->{asp}->Error("Can't unlock $file: $err");		
	    }
	}
    } else {
	# don't debug about this, since we'll always get some
	# of these since we are a bit over zealous about unlocking
	# better to unlock to much than too little
    }

    1;
}

sub UserLock {
    my $self = $_[0];
    
    unless($self->{user_lock}) {
	$self->{user_lock} = 1;
	$self->WriteLock();
    }
}

sub UserUnLock {
    my $self = $_[0];
    
    if($self->{user_lock}) {
	$self->{user_lock} = 0;
	$self->UnLock();
    }
}   

1;

# this package emulates an Apache request object with a CGI backend
package Apache::ASP::CGI;
$StructsDefined = 0;

sub do_self {
    my($r) = &init($0, @ARGV);
    $r->dir_config('CgiDoSelf', 1);
    $r->dir_config('NoState', 0);
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
    my $cgi = CGI->new({@args});

    $self->cgi($cgi);
    $self->filename($filename);
    $self->header_in('Cookie', $ENV{HTTP_COOKIE});
    $self->connection->remote_ip($cgi->remote_host());
    $self->dir_config('Global') || $self->dir_config('Global', '.');

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
    my($k, $v, $header);
    
    $self->sent_header(1);
    $header = "Content-Type: " .$self->content_type()."\n";
    my $headers = $self->header_out();
    while(($k, $v) = each %$headers) {
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

sub register_cleanup { 1; } # do nothing as cgi will cleanup anyway

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
	$self->{$key} = $value;
    } else {
	$self->{$key};
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

__END__

=head1 NAME

 Apache::ASP - Active Server Pages for Apache (all platforms)

=head1 SYNOPSIS

 SetHandler perl-script
 PerlHandler Apache::ASP
 PerlSetVar Global /tmp # must be some writeable directory

=head1 DESCRIPTION

This module provides a Active Server Pages port to Apache with perl
as the host scripting language. Active Server Pages is a web 
application platform that originated with Microsoft's IIS server.  
Under Apache for both Win32 and Unix, it allows a developer to 
create dynamic web applications with session management and perl code
embedded in static html files.

This is a portable solution, similar to ActiveWare's PerlScript
and MKS's PScript implementation of perl for IIS ASP.  Work has
been done and will continue to make ports to and from these
other implementations as seemless as possible.

For database access, ActiveX, and scripting language issues, please read 
the FAQ at the end of this document.

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
 # Included files may also be in this directory, please see 
 # section on includes for more information.
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
 # a time may run, per user $Session, with sessions allowed.
 # 
 # Serialized requests to the session object is the Microsoft ASP way, 
 # but is dangerous in a production environment, where there is risk
 # of long-running or run-away processes.  If these things happen,
 # a session may be locked for an indefinate period of time.  A user
 # STOP button should safely quit the session however.
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
 PerlSetVar SoftRedirect 0

 # NoState
 # -------
 # default 0, if true, neither the $Application nor $Session objects will
 # be created.  Use this for a performance increase.  Please note that 
 # this setting takes precedence over the AllowSessionState setting.
 #
 PerlSetVar NoState 0

 # StateDir
 # --------
 # default $Global/.state.  State files for ASP application go to 
 # this directory.  Where the state files go is the most important
 # determinant in what makes a unique ASP application.  Different
 # configs pointing to the same StateDir are part of the same
 # ASP application.
 # 
 # The default has not changed since implementing this config directive.
 # The reason for this config option is to allow OS's with caching
 # file systems like Solaris to specify a state directory separatly
 # from the Global directory, which contains more permanent files.
 # This way one may point StateDir to /tmp/asp, and make one's ASP
 # application scream with speed.
 #
 PerlSetVar StateDir ./.state

 # StateManager
 # ------------
 # default 10, this number specifies the numbers of times per SessionTimeout
 # that timed out sessions are garbage collected.  The bigger the number,
 # the slower your system, but the more precise Session_OnEnd's will be 
 # run from global.asa, which occur when a timed out session is cleaned up,
 # and the better able to withstand Session guessing hacking attempts.
 # The lower the number, the faster a normal system will run.  
 #
 # The defaults of 20 minutes for SessionTimeout and 10 times for 
 # StateManager, has dead Sessions being cleaned up every 2 minutes.
 #
 PerlSetVar StateManager 10

 # Filter
 # ------
 # default Off.  With filtering enabled, you can take advantage of 
 # full server side includes (SSI), implemented through Apache::SSI.  
 # SSI is implemented through this mechanism by using Apache::Filter.  
 # A sample configuration for full SSI with filtering is in the 
 # eg/.htaccess file, with a relevant example script eg/ssi_filter.ssi.
 # 
 # You may only use this option with modperl v1.16 or greater installed
 # and PERL_STACKED_HANDLERS enabled.  Filtering may be used in 
 # conjunction with other handlers that are also "filter aware".
 #
 # With filtering through Apache::SSI, you should expect at least
 # a 20% performance decrease, increasing as your files get bigger, 
 # increasing the work that SSI must do.
 PerlSetVar Filter On

 # PodComments
 # -----------
 # default 1.  With pod comments turned on, perl pod style comments
 # and documentation are parsed out of scripts at compile time.
 # This make for great documentation and a nice debugging tool,
 # and it lets you comment out perl code and html in blocks.  
 # Specifically text like this:
 # 
 # =pod
 # text or perl code here
 # =cut 
 #
 # will get ripped out of the script before compiling.  The =pod and
 # =cut perl directives must be at the beginning of the line, and must
 # be followed by the end of the line.
 PerlSetVar PodComments 1

 </Location>

 ##ASP##PERL##APACHE##UNIX##WINNT##ASP##PERL##APACHE##NOT##IIS##ASP##
 ## END INSERT
 ##ASP##PERL##APACHE##ACTIVE##SERVER##PAGES##SCRIPTING##!#MICROSOFT##

You can use the same config in .htaccess files without the 
Location tag.  I use the <Files ~ (\.asp)> tag in the .htaccess
file of the directory that I want to run my asp application.
This allows me to mix other file types in my application,
static or otherwise.  Again, please see the ./eg directory 
in the installation for some good starter .htaccess configs,
and see them in action on the example scripts.

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

=head1 The Event Model & global.asa

The ASP platform allows developers to create Web Applications.
In fulfillment of real software requirements, ASP allows 
event-triggered actions to be taken, which are defined in
an application's - global.asa - file.  The global.asa file
resides in the application's - Global - directory, and may
define the following actions:

	Action			Event
	------			------
	Application_OnStart	Beginning of Application
	Application_OnEnd	End of Application
	Session_OnStart		Beginning of user's Session.
	Session_OnEnd		End of user's Session.

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

=head2 Application_OnStart

This event marks the beginning of an ASP application, and 
is run just before the Session_OnStart of the first Session
of an application.  This event is useful to load up
$Application with data that will be used in all user sessions.

=head2 Application_OnEnd

The end of the application is marked by this event, which
is run after the last user session has timed out for a 
given ASP application.  

=head2 Session_OnStart

Triggered by the beginning of a user's session, Session_OnStart
get's run before the user's executing script, and if the same
session recently timed out, after the session's triggered Session_OnEnd.

The Session_OnStart is particularly useful for caching database data,
and avoids having the caching handled by clumsy code inserted into
each script being executed.

=head2 Session_OnEnd

Triggered by a user's session ending, Session_OnEnd can be useful
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

=item $Application->SessionCount()

This NON-PORTABLE method returns the current number of active sessions,
in the application.  This method is not implemented as part of the ASP
object model, but is implemented here because it is useful.  In particular,
when accessing databases with license requirements, one can monitor usage
effectively through accessing this value.

This is a new feature, and if run on a site with previous versions of 
Apache::ASP, the count may take a while to synch up.  To ensure
a correct count, you must delete all the current state files associated
with an application, usually in the $Global/.state directory.

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

=head1 COMPATIBILITY

=head2 CGI

CGI has been the standard way of deploying web applications long before
ASP came along.  CGI.pm is a very useful module that aids developers in 
the building of these applications, and Apache::ASP has been made to 
be compatible with function calls in CGI.pm.  Please see cgi.htm in the 
./eg directory for a sample ASP script written almost entirely in CGI.

Following are some special notes with respect to compatibility with CGI.
Use of CGI.pm in any of these ways was made possible through a great
amount of work, and is not gauranteed to be portable with other perl ASP
implementations.

=over

=item Query Object Initialization

You may create a CGI $query object like so:

	use CGI;
	my $query = new CGI;

But because POST data has already been read by Apache::ASP, you will
not get any use of reading input with the $query object normally.
If you initialize the object with $Request data, you may
get input like so:

	my $query = new CGI({ %{$Request->Form}, %{$Request->QueryString} });
	my $data = $query->param('some_input_field_name');

=item print()ing CGI

CGI is notorious for its print() statements, and the functions in CGI.pm 
usually return strings to print().  You can do this under Apache::ASP.

	print $query->header();
	print $query->start_form();

=item File Upload

CGI.pm is used for implementing reading the input from file upload.  You
may create the file upload form however you wish, and then the 
data may be recovered from the file upload by using $Request->Form().
Data from a file upload gets written to a filehandle, that may in
turn be read from.  The original file name that was uploaded is the 
name of the file handle.

	my $filehandle = $Request->Form('file_upload_field_name');
	print $filehandle; # will get you the file name
	my $data;
	while(read($filehandle, $data, 1024)) {
		# data from the uploaded file read into $data
	};

Please see the docs on CGI.pm (try perldoc CGI) for more information
on this topic, and ./eg/file_upload.asp for an example of its use.

=back

=head2 PerlScript

Much work has been done to bring compatibility with ASP applications
written in PerlScript under IIS.  Most of that work revolved around
bringing a Win32::OLE Collection's interface to many of the objects
in Apache::ASP, which are natively written as perl hashes.

The following objects in Apache::ASP respond as Collections:

	$Application
	$Session
	$Request->Form
	$Request->QueryString
	$Request->Cookies
	$Response->Cookies
	$Response->Cookies('Any Cookie')

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
 > Win32::OLE::in may not be used.  Use keys() to iterate over Collections.
 > The ->{Item} property is parsed automatically out of scripts, use ->Item().

=head1 FAQ

=over

=item How is database connectivity handled?

Database connectivity is handled through perl's DBI & DBD interfaces.
Please see http://www.hermetica.com/technologia/perl/DBI/ for more information.
In the UNIX world, it seems most databases have cross platform support in perl.

DBD::ODBC is often your ticket on Win32.  On UNIX, commercial vendors
like OpenLink Software (http://www.openlinksw.com/) provide the nuts and 
bolts for ODBC.

=item Do I have access to ActiveX objects?

Only under Win32 will developers have access to ActiveX objects through
the perl Win32::OLE interface.  This will remain true until there
are free COM ports to the UNIX world.  At this time, there is no ActiveX
for the UNIX world.

=item Can I script in VBScript or JScript ?

Yes, but not with this perl module.  For ASP with other scripting
languages besides perl, you will need to go with a commercial vendor
in the UNIX world.  ChiliSoft (http://www.chilisoft.com/) has one
such solution.  Of course on NT, you get this for free with IIS.

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
 :) Bryan Murphy, for being a PerlScript wiz
 :) Francesco Pasqualini, for bringing ASP to CGI
 :) Michael Rothwell, for his love of Session hacking
 :) Lincoln Stein, for his blessed CGI module
 :) Alan Sparks, for knowing when size is more important than speed
 :) Jeff Groves, who put a STOP to user stop button woes
 :) Matt Sergeant, for his excellect tutorial on PerlScript
 :) Ken Williams, for great teamwork bringing full SSI to the table
 :) Darren Gibbons, the biggest cookie-monster I've ever known.
 :) Doug Silver, for finding all the bugs.

=head1 SUPPORT

Please send any questions or comments to the Apache modperl mailing
list at modperl@apache.org or to me at chamas@alumni.stanford.org.

=head1 COPYRIGHT

Copyright (c) 1998, Joshua Chamas. 

All rights reserved. This program is free software; 
you can redistribute it and/or modify it under the same 
terms as Perl itself. 

=cut








