#!/usr/local/bin/perl

use Benchmark;
use XML::XSLT;
use Carp qw(confess);
use strict;

$SIG{__DIE__} = \&confess;
my $xsl_data = &xsl_data;
my $xml_data = &xml_data;

my $num = $ARGV[0] || 1;
$XSLT::debug = $num == 1 ? 1 : 0;
defined $ARGV[1] and $XML::XSLTParser::_indent_incr = $ARGV[1];

my $xsl = XML::DOM::Parser->new->parse($xsl_data);
# my $xml = XML::DOM::Parser->new->parse($xml_data);

my $result;
print "starting test...\n\n";
timethis ($num, sub 
	  {
	      my $parser = XML::XSLTParser->new();
	      $parser->open_project ($xml_data, $xsl, 'STRING', 'DOM');
	      $parser->process_project;
	      $result = $XSLT::result->toString;	      
	      $parser->DESTROY();
});


print $result;
sleep 5;
exit;

sub xsl_data {
    my $data = <<DATA;
<?xml version="1.0"?> 
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">

<xsl:template match="page">
 <html>
  <head>
   <title><xsl:value-of select="title"/></title>
  </head>
  <body bgcolor="#ffffff">
   <xsl:apply-templates/>
  </body>
 </html>
</xsl:template>

<xsl:template match="title">
 <h2>
  <xsl:apply-templates/>
 </h2>
</xsl:template>

<xsl:template match="paragraph">
 <p>
  <i><xsl:apply-templates/></i>
 </p>
</xsl:template> 

</xsl:stylesheet>
DATA
  ;
}

sub xml_data {
    my $data =<<DATA;
<?xml version="1.0"?>
<page>
 <title>Hello World!</title>
 <content>
  <paragraph>This is my first XSLT enabled Apache::ASP page!</paragraph>
 </content>
</page>
DATA
  ;
}
