#!/usr/local/bin/perl

my $include = q/<% my %items=(); if ($Session->{'edit_mode'})
{%><!--#include file=e_header.inc args=\%items--><%} else
{%><!--#include file=header.inc args=\%items--><%}%>/;

print $include;
