$Config{Debug} = 0;
if($0 =~ /asp$/) {
	$Config{NoState} = 0;
	$Config{StateDir} = '/tmp/aspdemo/';
} else {
	$Config{NoState} = 1;
}

