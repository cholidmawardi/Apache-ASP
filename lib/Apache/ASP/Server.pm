
package Apache::ASP::Server;
use strict;
use vars qw($OLESupport);

sub new {
    bless {asp => $_[0]};
}

sub DESTROY {}

sub CreateObject {
    my($self, $name) = @_;
    my $asp = $self->{asp};

    # dynamically load OLE at request time, especially since
    # at server startup, this seems to fail with "start_mutex" error
    #
    # no reason to preload this unix style when module loads
    # because in win32, threaded model does not need this prefork 
    # parent httpd compilation
    #
    unless(defined $OLESupport) {
	eval 'use Win32::OLE';
	if($@) {
	    $OLESupport = 0;
	} else {
	    $OLESupport = 1;
	}
    }

    unless($OLESupport) {
	die "OLE-active objects not supported for this platform, ".
	    "try installing Win32::OLE";
    }

    unless($name) {
	die "no object to create";
    }

    Win32::OLE->new($name);
}

sub Execute {
    my $self = shift;
    $self->{asp}{Response}->Include(@_);
}

sub File {
    shift->{asp}{filename};
}

sub Transfer {
    my $self = shift;
    $self->{asp}{Response}->Include(@_);
    $self->{asp}{Response}->End;
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

    if(ref($toencode)) {
	$$toencode=~s/&/&amp;/sg;
	$$toencode=~s/\"/&quot;/sg;
	$$toencode=~s/>/&gt;/sg;
	$$toencode=~s/</&lt;/sg;
    } else {
	$toencode=~s/&/&amp;/sg;
	$toencode=~s/\"/&quot;/sg;
	$toencode=~s/>/&gt;/sg;
	$toencode=~s/</&lt;/sg;
    }

    $toencode;
}

sub RegisterCleanup {
    my($self, $code) = @_;
    if(ref($code) =~ /^CODE/) {
	$self->{asp}{dbg} && $self->{asp}->Debug("RegisterCleanup() called", caller());
	push(@{$self->{asp}{cleanup}}, $code);
    } else {
	$self->{asp}->Error("$code need to be a perl sub reference, see README");
    }
}

sub MapInclude {
    my($self, $file) = @_;
    $self->{asp}->SearchDirs($file);
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
	my @values = (ref($v) and ref($v) eq 'ARRAY') ? @$v : ($v);
	for my $value ( @values ) {
	    $value =~ s/([^a-zA-Z0-9_\-.])/uc sprintf("%%%02x",ord($1))/egs;
	    push(@query, $k.'='.$value);
	}
    }
    if(@query) {
	$url .= '?'.join('&', @query);
    }

    $url;
}

sub XSLT {
    my($self, $xsl_data, $xml_data) = @_;
    $self->{asp}->XSLT($xsl_data, $xml_data);
}

sub Config {
    my($self, $key, $value) = @_;
    
    if(defined $value) {
	$self->{asp}{r}->dir_config($key, $value);
    } elsif(defined $key) {
	$self->{asp}{r}->dir_config($key);
    } else {
	$self->{asp}{r}->dir_config;
    }
}

1;
