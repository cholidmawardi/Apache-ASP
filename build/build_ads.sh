#!/bin/sh

#../cgi/asp -b -o ../site index.html ads 1 
../cgi/asp -b -o ../site index.html ads 1 ./*.html
\cp -rfp /proj/link/asp/src/site/* /proj/link/site/asp
