package Apache::ASP::ApacheCommon;

# For mod_perl 2.0 in particular, just load all the modules
# Loading only the modules needed in particular only saved between 500K-2M
# during benchmarking
# eval { &ModPerl::MethodLookup::preload_all_modules(); };
	
# here is the list of modules from mod_perl 2.0 that I would need to load
# explicitly for all the Apache methods needed.  This is by no means definitive
# but what I found during testing.
# --jc, 5/5/2003

use Apache2::RequestRec ();
use Apache2::RequestUtil ();
use Apache2::RequestIO ();
use Apache2::Response ();
use APR::Table ();
use APR::Pool ();
use Apache2::Connection ();
use Apache2::ServerUtil ();
use Apache2::ServerRec ();
use Apache2::SubRequest ();
use Apache2::Log ();

1;
