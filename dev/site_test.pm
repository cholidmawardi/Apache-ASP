
################################################################
# Define ONLY site:: variables/functions here !!!
################################################################
#

#use strict;
use DBI;

######################################################
# Site variables (all in SITE_INFO)
######################################################

package site;

$site::SITE_INFO=
        {    path => "/spotlight" ,
             something => "else"
        };


#################################################################
# Functions
#################################################################



#################################################################
# critical_error($query)
#################################################################
#
# INPUT:
#  $query - The query that gave an error
#
# RETURN:
#  none
#
# DESCRIPTION:
#  Simply quits the application, after showing on the
#  standard output the error page "critical_error.psp"
#
##################################################################
#
#
sub critical_error($){
	$Response->Include("critical_error.psp",$_[0]);
	$Response->End()
}



################################################################
# Database retreive/lookup functions
################################################################

#################################################################
# database_query($mode,$query)
#################################################################
#
# INPUT:
#  $mode  - Two character string. 
#           $mode[0] can be "S" (single result) 
#                        or "M" (many results)
#
#           $mode[1] can be "N" (do NOT allow empty result)
#                        or "Y" (allow empty result)
#
#  $query - Query to be executed
#
# RETURN:
#  $result - This variable can be two things.
#            IF $mode[0] was "S", it's a hashref. 
#                                 e.g.: $result->{field_10}
#            IF $mode[0] was "M", it's a arrayref with hashref 
#                                 e.g.: $result->[6]{field_10}
#
# DESCRIPTION:
#  This is the ONLY function that actually performs the query
#  to the database. You are ALWAYS sure that the result is
#  a hashref or arrayref, even if the query was empty.
#  Even the search engine uses this function to query.
#  if an empty result was NOT allow, and the result was... empty,
#  the function critical_error is called and the application quits
#
##################################################################
#
#
sub site::database_query($$)
{
	my($mode)=$_[0];
	my($query)=$_[1];
	my($sth);
	my($result,$i,%new_hash,$extra_bit,$count,$tmp);
	my($return_value);


	###########################
	# First character: S or M
	# Default: S
	###########################
	#
	if (substr($mode,0,1) ne "S" && substr($mode,0,1) ne "M"){
		substr($mode,0,1)="S";
	}

	###########################
	# First character: Y or N
	# Default: N
	###########################
	#
	if (substr($mode,1,1) ne "Y" && substr($mode,1,1) ne "N"){
		substr($mode,1,1)="N";
	}


	#################################
	# Run the query
	################################
	#
	$sth = $site::dbh->prepare("$query"); 
	$sth->execute();

	#######################################
	# Only 1 result format ("S"): allocate
	# %new_hash and return it!
	#######################################
	#
	if( substr($mode,0,1) eq "S" ){

		$result = $sth->fetchrow_hashref();


		##################################
		# If no empty query was
		# allowed, go in critical_error
		##################################
		#
		if(!$result && substr($mode,1,1) eq "N"){
			site::critical_error($query);
		}

	
		#############################
		# Return the hash, empty if
		# there were NO results
		#############################	
		my(%new_hash)=();
		if($result){
			%new_hash=%{$result};
		}

		return(\%new_hash);

	}
	
	else {

		##################################
		# Cycle to create $return_value
		##################################
		#
		$return_value=[];
		$count=0;
		while( $result = $sth->fetchrow_hashref()){

			###############################
			# Make sure I allocate a brand
			# new associative array
			###############################
			#
			my(%new_hash)=%{$result};

			#########################
			# Add up the item to
			# the return value
			#########################
			#
			$return_value->[$count]=\%new_hash;	
	
			$count++;
		}

		##################################
		# If no empty query was
		# allowed, go in critical_error
		##################################
		#
		if($count==0 && substr($mode,1,1) eq "N"){
                        site::critical_error($query);
                }

		return($return_value);


	}

}

#################################################################
# retrieve_product_group_1()
#################################################################
#
# INPUT:
#  none
#
# RETURN:
#  $result - 
#
# DESCRIPTION:
#
#
##################################################################
#
#
sub retrieve_product_group_1()
{
	my($result,$i,@tmp,$last_stock_group);

	$result=site::database_query("MN","SELECT * FROM product_groups");

	
	$last_stock_group="";
	for($i=0;$i<@{$result};$i++){
		@tmp = split(" ",$result->[$i]{sys_description});
		$result->[$i]{sys_description} = $tmp[0];
		
		@tmp= substr($result->[$i]{stock_group},0,1);
		$result->[$i]{stock_group} = $tmp[0];

		if ( $result->[$i]{stock_group} eq $last_stock_group){
			undef($result->[$i]);
		}
		else{
			$last_stock_group=$result->[$i]{stock_group};
		}
		
	}
	return $result;		
}


sub retrieve_product_group_2($)
{
	my($filter)=$_[0];
	my($result,$i,@tmp,$last_stock_group);

	###########################
	# Just to be sure...
	###########################
	#
	$filter=substr($filter,0,1);

	$result=site::database_query("MN","SELECT * FROM product_groups WHERE stock_group LIKE '$filter%'");

	for($i=0;$i<@{$result};$i++){
		@tmp = split(" ",$result->[$i]{sys_description});
		$result->[$i]{sys_description} = $tmp[1];
	}

	return($result);
}


sub retrieve_color_codes()
{
	my($result,$i,%return_value);

	$result=site::database_query("MN","SELECT * FROM color");

	for($i=0;$i<@{$result};$i++){
		$return_value{ $result->[$i]{color_id} } = $result->[$i]{color_name};
        }

	return(\%return_value);

}

sub retrieve_available_colors($)
{
	my($stock_code)=$_[0];
	my($result,@color_array);

	$result=site::database_query("SY","SELECT * FROM product_available_color
                                                   WHERE stock_code='$stock_code'");

	@color_array=split(/,/,$result->{color});

	if(!@color_array){ return (); };

	return @color_array;
}

##############################################################
# Shopping basket functions
##############################################################

sub add_to_shopping_basket($$$)
{

	my($stock_code) = $_[0];
	my($color) = $_[1];
	my($quantity) = $_[2];
	my($cc,@color_array);
	my($res1,$res2,$res3,$s_sb,$i);

	####################################################
	# Input control
	####################################################
	#

	
	################################
	# The stock_code MUST be in the
	# pronto_product_list table
	################################
	#
	$res1=site::database_query("SN","SELECT * FROM pronto_product_list
					  WHERE stock_code='$stock_code'");
	$res2=site::database_query("SN","SELECT * FROM product_list_pronto_link
					  WHERE stock_code='$stock_code'");
	$res3=site::database_query("SN","SELECT * FROM product_list
					  WHERE img_id='$res2->{img_id}'");

	##############################
	# Quantity must be a number,
	# and must not be ""
	##############################
	#
	if($quantity =~ /[^0-9]/ || $quantity eq "" ) {
		return;
	}

	################################################
	# 1) If a color is chosen, the product must
	#    have a list of available colors
	# 2) If a color is NOT chosen, the product
	#    MUST NOT have any color available
	# 3) If a color is chosen, that color MUST
	#    exist for that product
	################################################
	#
	@color_array = site::retrieve_available_colors($stock_code);
	if( @color_array != 0 && $color eq "" ){ return; }
	if(@color_array == 0 && $color ne "" ){ return; }
	if( $color ne "" && !($i=grep(/^$color$/,@color_array)) ){ return; };


	######################################################
	# Adding stuff! (finally :-) )
	######################################################
	#
	$s_sb=$Session->{s_sb};
	$s_sb->{$stock_code}{$color}{quantity}   += $quantity;
	$s_sb->{$stock_code}{$color}{description} = "$res3->{description} ($res2->{extra_info})";
	$Session->{s_sb}=$s_sb;

}


sub del_from_shopping_basket($$) {
	my($stock_code) = $_[0];
	my($color) = $_[1];
	my($s_sb);

	$s_sb=$Session->{s_sb};
	delete $s_sb->{$stock_code}{$color};
	$Session->{s_sb}=$s_sb;
}


sub show_shopping_basket(){
	my($s_sb);
	my(@i,$i,$j);
	my($cc);

	###################################
	# Put the shopping basket hashref
	# in "s_sb"
	###################################
	#
	$s_sb = $Session->{s_sb};

	############################
	# It must know about the color
	# codes...!
	############################
	#
	$cc=site::retrieve_color_codes();

	############################
	# Showing the first bit
	############################
	#
	$Response->Write("<HR>\n");
	$Response->Write("<H3>Shopping basket:</H3>\n");

	##############################
	# Is it empty?
	##############################
	#
	if(!keys(%{$s_sb})){
		$Response->Write("<H4>The shopping basket is empty!</H4>\n");
		return;
	}


	########################
	# First bit of the table
	########################
	#
	$Response->Write("<TABLE BORDER=10>\n");
	$Response->Write("<TR> <TD>Product</TD> <TD>Color</TD> <TD>Quantity</TD> </TR>\n");
		

	############################
	# Show the elements
	############################
	#		
	for $i (keys(%{$s_sb}) ){
		for $j (keys(%{ $s_sb->{$i} })) {
			$Response->Write("<TR> <TD>$s_sb->{$i}{$j}{description}</TD> <TD>$cc->{$j}</TD> <TD>$s_sb->{$i}{$j}{quantity}</TD></TR>\n");
		}
	}

	###########################
	# Close the table up...
	###########################
	#
	$Response->Write("</TABLE>\n");
	$Response->Write("</HR>\n");

}



#####################################################
# Site functions
#####################################################


sub read_specials {
        my( $specials_vector );
        my( $specials_text );
        my( $file_name , $file_length );
        my( $i , $env );


        #$Response->Write("BBAAAAAHHHHHHHHHHHHHHHHH<P>\n");
	#$env = $Request->ServerVariables();
	#for $i (keys(%{$env})){
        #	$Response->Write("$i <P>\n");
	#}
	$file_name = $Server->MapPath(".") . "\n";

        #$Response->Write("The path IS: $file_name <P>\n");

}       
      
