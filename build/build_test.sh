#!/bin/bash

#perl ../cgi/asp -b -o ../site ./*.html
#perl /perl/bin/pod2text -80 < ../ASP.pm  > ../README
#perl ../cgi/asp -b -o ../site ./index.html ads 1 
perl ../cgi/asp -b -o ../site ./index.html ads 1 ./*.html
\cp -rfp /proj/link/asp/src/site/* z:/site/asp
