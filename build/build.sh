#!/bin/bash

perl /perl/bin/pod2text -80 < ../ASP.pm  > ../README
../cgi/asp -b -o ../site ./*.html
