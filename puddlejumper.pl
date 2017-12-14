#!/usr/bin/env perl
use strict;
use warnings;
use JSON;
use WWW::Curl::Easy;
use Getopt::Long;
use POSIX qw/strftime/;
use Config::Simple;
use Pod::Usage;

=pod 

=head1 puddlejumper
puddlejumper - switch between mining pools based on data from whattomine.com

=cut

# Default Options
my $threshhold         = 10; # percentage difference
my $sort_parameter     = 'btc_revenue';
my $check_timer        = 10; # Minutes
my $cfg_file           = 'puddlejumper.cfg';

my $test_mode	       = 'no';
my $missing_log        = 'missing.txt';
my $work_log           = 'work_log.csv';
my $url;


# Read from config file
my $config = new Config::Simple($cfg_file);

# Fail if the whattomine url is not configured in the 
if (defined $config->param("url")) {
	$url                = $config->param("url");
	$url =~ s/coins/coins.json/;
}
else {
	print "Please configure the url option in the config file\n";
	exit(1);
}

# Read from command line flags
GetOptions ('threshhold=s' => \$threshhold,
            'timer=s' => \$check_timer,
            'test:s'=>\$test_mode);

=pod

=head1 SYNOPSIS
puddlejumper [options] 
 Options:
    --help		This help mesage
    --url		--depreciated-- Nicehash URL to save cookie
    --threshhold	Percentage diffference required to switch coins
    --parameter		Parameter to sort whattomine data on
    --timer          	How often in minutes to check for changes
    --cookie		whattomine cookie file
    --config		configuration file
    --test 		Test coin configuration
    --missing_log	Log file for missing coins info
    --work_log 		Log file for coins mined
=head1 OPTIONS
=over 4
=item B<--url> --Depreciated--
    URL should be the url you get from whattomine.com after configuring your hashrates and clicking calculate here. Wrap in quotes.
=item B<--timer>
    This is time in minutes between updates from whattomine.com.  Checking more often then 3 minutes is pointless.
    Defaulit: 10
=item B<--parameter>
    The parameter from whattomine json data to sort on.  Not all of the valid values will produce usefull results.
    Valid values:
    id, tag, algorithm, block_time, block_reward, block_reward24, last_block, difficulty, difficulty24, nethash, exchange_rate, exchange_rate24, exchange_rate_vol, exchange_rate_curr, market_cap, estimated_rewards, estimated_rewards24, btc_revenue, btc_revenue24, profitability, profitability24
    Default: btc_revenue
=item B<--threshhold>
    Switch to the new top algorithm if the sort field is differnt by this percentage.
    Default: 10
=item B<--cookie>
    The configured cookie file to use.
    Default: cookies.txt
=item B<--config>
    The configuration file to use.
    Default: puddlejumper.cfg
=item B<--test [coin]>
    Test coin or all coins for an amount of time spesified by --timer. Spesify coin to test, or leave blank to test all coins.
=item B<--missing_log>
    Log file to log coins that were bypassed do to missing configuration.
=item B<--work_log>
    Log file to log what coins have been mined.
=back

=cut


if ($test_mode ne 'no') {
	test_coins($test_mode);
	exit(0);
}

# Setup curl
my $curl = WWW::Curl::Easy->new();
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
			       	print "$time -- Continue mining $current_coin at (btc):" .$coins->{$current_coin}->{'btc_revenue'} . ".  Difference less then threshhold.\n";
			}

		}
		print "$time -- Continue mining $current_coin at (btc):" .$coins->{$current_coin}->{'btc_revenue'} . ".  Currently most profitable.\n";
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
