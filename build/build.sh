#!/bin/bash

perl /perl/bin/pod2text -80 < ../ASP.pm  > ../README
perl ../cgi/asp -b -o ../site ./*.html
#perl ../cgi/asp -b -o ../site ./index.html
