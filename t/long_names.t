
use Apache::ASP::CGI;
&Apache::ASP::CGI::do_self(NoState => 1, 
			   Global => 'long_names/long_directory_path/long_directory_path/long_directory_path/long_directory_path/long_directory_path',
			   Debug => 0,
);

__END__

<% $Response->Include('ok.inc'); %>
