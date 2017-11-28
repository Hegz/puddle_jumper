#!/usr/bin/env perl
use strict;
use warnings;
use JSON;
use WWW::Curl::Easy;
use Getopt::Long;
use POSIX qw/strftime/;
use Config::Simple;


# Default Options
my $url                = 'https://whattomine.com/coins.json'; 
my $threshhold         = 10; # percentage difference
my $sort_parameter     = 'btc_revenue';
my $check_timer        = 10; # Minutes
my $cookies_file       = 'cookies.txt';
my $cfg_file           = 'puddlejumper.cfg';
my $test_mode	       = 'no';

# Read from config file
my $config = new Config::Simple($cfg_file);

# Read from command line flags
GetOptions ('config=s' => \$url,
	    'threshhold=s' => \$threshhold,
            'timer=s' => \$check_timer,
            'test:s'=>\$test_mode);


if ($test_mode ne 'no') {
	test_coins($test_mode);
	exit(0);
}

# Setup curl
my $curl = WWW::Curl::Easy->new();
$curl->setopt(CURLOPT_COOKIEFILE, $cookies_file ); 
$curl->setopt(CURLOPT_COOKIEJAR, $cookies_file ); 
$curl->setopt(CURLOPT_HEADER,0);
$curl->setopt(CURLOPT_URL, $url);

my $current_coin;
my $mining = '';
my $PID;

# Main program loop
while (1) {
	my $response_body;
	$curl->setopt(CURLOPT_WRITEDATA,\$response_body);

	# Starts the actual request
	my $retcode = $curl->perform;

	# Don't process further if we're not dealing with JSON
	if ($url ne 'https://whattomine.com/coins.json') {
		print "Cookie file created/update as $cookies_file.\n";
		exit (0);
	}

	# Looking at the results...
	if ($retcode == 0) {
		my $json = decode_json $response_body;
		my $coins = $json->{'coins'};
		my @sort_coins = sort { $coins->{$b}->{$sort_parameter} <=> $coins->{$a}->{$sort_parameter}} keys %{$coins};
		
		my $coin;
		my $time = strftime('%Y-%m-%d %H:%M',localtime);
	
		# Find the best coin that we have configuration for
		for ( @sort_coins ) {
			if ( !defined ($config->param("Coins.$_"))) {
				print "$time -- No configuration found for $_ at $coins->{$_}->{'btc_revenue'}\n";
			}
			else{
				$coin = $_;
				last;
			}
		}
		
		# Engage Mining on the first coin
		if ( !defined($current_coin)) {
			$current_coin = $coin;
			print "$time -- Begin mining  " . $coin . ". at (btc):" .$coins->{$current_coin}->{'btc_revenue'} . "\n";
		}

		# Check for a switch to the new coin
		elsif ($coins->{$coin}->{$sort_parameter} > $coins->{$current_coin}->{$sort_parameter}) {
			# Check to see if we are above the threshold
			if (1 - ($coins->{$current_coin}->{$sort_parameter} / $coins->{$coin}->{$sort_parameter}) > ($threshhold / 100)) {
			       	# We are above the threshhold, report a change
			       	print "$time -- Switiching to $coin at (btc):" .$coins->{$coin}->{'btc_revenue'} . "\n";
				$current_coin = $coin;
			}
			else {
			       	print "$time -- Continue mining $current_coin at (btc):" .$coins->{$current_coin}->{'btc_revenue'} . "\n";
			}

		}
	} 
	else {
		# Error code, type of error, error message
		print("An error happened: $retcode ".$curl->strerror($retcode)." ".$curl->errbuf."\n");
	}
	if ($mining ne $current_coin) {
		if (defined $PID) {
			kill 1, $PID;
		}
		$PID = fork ();
		if (! $PID) {
			my $cmd = $config->param("Coins.$current_coin");
			
			# Sub Account values from the config file
			my $account = $config->param(-block=>'Accounts');
			for (keys %{$account}) {
				$cmd =~ s/<$_>/$account->{$_}/;
			}
			exec ($cmd);
		}
		else {
			$mining = $current_coin;
		}
	}
	sleep $check_timer * 60;
}

sub test_coins {
	my $test_mode = shift @_;
	# Loop through the defined coins and test them
	my $coins;
	if (defined $config->param("Coins.$test_mode")){

		$coins->{$test_mode} = $config->param("Coins.$test_mode");
	}
	else {
		$coins = $config->param(-block=>'Coins');
	}

	for (keys %{$coins}){
		my $PID = fork ();
		if (! $PID) {
			my $cmd = $coins->{$_};
			
			# Sub Account values from the config file
			my $account = $config->param(-block=>'Accounts');
			for (keys %{$account}) {
				$cmd =~ s/<$_>/$account->{$_}/;
			}

			print "Testing $_ for $check_timer minutes.\n";
			print "$cmd\n\n";
			exec ($cmd);
		}
		sleep $check_timer * 60;
		kill 1, $PID;
	}
}

