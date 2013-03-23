#!/usr/bin/perl
###########################################
# ebaywatch
# Mike Schilli, 2003 (m@perlmeister.com)
# Karsten von Hornbostel, 2011 (kaback_spam@yahoo.de)
###########################################

use warnings;
use strict;
use Config::Simple;

#TODO check if config file exists
our $config = new Config::Simple($ENV{HOME}."/.ebaywatchrc");

our $JABBER_ID      = $config->param(-block=>'jabber')->{id};
our $JABBER_PASSWD  = $config->param(-block=>'jabber')->{passwd};
our $JABBER_SERVER  = $config->param(-block=>'jabber')->{server};
our $JABBER_PORT    = $config->param(-block=>'jabber')->{port};
our $SEEN_DB_FILE   = $config->param(-block=>'general')->{seen_db_file};
our $SEARCH_FILE   =  $config->param(-block=>'general')->{searchterms_file};
our %SEEN;

use Net::Jabber qw(Client);
use DB_File;
use Log::Log4perl qw(:easy);
use eBay::API::Simple::Finding;

Log::Log4perl->easy_init( { level => $DEBUG, 
                           file => ">>/tmp/ebaywatch.log" } 
);

tie %SEEN, 'DB_File', $SEEN_DB_FILE, 
    O_CREAT|O_RDWR, 0755 or 
    LOGDIE "tie: $SEEN_DB_FILE ($!)";

END { untie %SEEN }

#create Ebay API object
my $call = eBay::API::Simple::Finding->new( { appid => $config->param(-block=>'ebay-api')->{appid}, 
                                              siteid => $config->param(-block=>'ebay-api')->{siteid} }
);

open FILE, "<$SEARCH_FILE" or LOGDIE "Cannot open $SEARCH_FILE ($!)";


# log in into jabber
my $c = Net::Jabber::Client->new();
$c->SetCallBacks(presence => sub {});
my $status = $c->Connect(
     hostname => $JABBER_SERVER,
     port     => $JABBER_PORT,
     timeout  => 1000,
);

LOGDIE "Can't connect to jabber: $!" 
    unless defined $status;

my @result = $c->AuthSend(
    username => $JABBER_ID,
    password => $JABBER_PASSWD,
    resource => $config->param(-block=>'jabber')->{my_resource},
);

LOGDIE "Can't log in: $!" 
    unless $result[0] eq "ok";

#$c->PresenceSend();

# iterate over search terms
while(<FILE>) 
{
	# Discard comment and empty lines
	s/^\s*#.*//;
	next if /^\s*$/;
	chomp;

	my $term = $_;

	# execute ebay api call
  	$call->execute( 'findItemsByKeywords', { keywords => $term } );

  	if ( $call->has_error() ) 
	{
		# first log out from jabber
		$c->Disconnect;
     		LOGDIE "Call Failed:" . $call->errors_as_string();
  	}

  	# getters for the response Hash
  	my $hash = $call->response_hash();

	# precess each search result
	# ATTENTION: when there is only oen single result, then a hash is resturned by the API instead of an array
	if ($hash->{'searchResult'}->{'count'} == 1)
	{
		process_result($hash->{'searchResult'}->{'item'});
	} else {
	  	for my $result (@{$hash->{'searchResult'}->{'item'}}) 
		{
			process_result($result);
		}
	}
}

# whe are done, logout from jabber
$c->Disconnect;


#####################
sub process_result {
#####################
	my($r) = @_;  
	#print Dumper($r);

    	#DEBUG "Result: ", $r->{'viewItemURL'},
 		# " ", $r->{'title'}, 
        	#" ", $r->{'itemId'}, 
        	#" ", $r->{'sellingStatus'}->{'timeLeft'};
    
    	if($SEEN{"url/" . $r->{'itemId'}}) 
	{
      		return;
    	}

	# calculate remaining time
    	my $mins = minutes($r->{'sellingStatus'}->{'timeLeft'});
    
    	INFO "Notify for ", $r->{'itemId'};
    	$SEEN{"url/" . $r->{'itemId'}}++;

	# build the jabber message
	my $msg = "";
    	my $title = $r->{'title'};
	$title =~ s/[^[:print:]]//g;
	my $price = $r->{'sellingStatus'}->{'currentPrice'}->{'content'};

	# fixed price auctions should be shown in a different color 	
      	if($r->{'listingInfo'}->{'listingType'} eq 'FixedPrice')
	{
    		$msg = $r->{'viewItemURL'} .
      			"\n" . "\e[0;35;40m$title" .  "\n" .
      			"(${mins}m) " .  "\e[0;33;40m$price";
	} else {
    		$msg = $r->{'viewItemURL'} .
      			"\n" . "\e[0;35;40m$title" .  "\n" .
      			"(${mins}m) " .  $price;
	}

	# send the jabber message
    	jabber_send($msg);
}
      

###########################################
sub minutes {
###########################################
    my($s) = @_;

    my $min = 0;

    $min += 60*24*$1 if $s =~ /(\d+)DT/;
    $min += 60*$1 if $s =~ /(\d+)H/;
    $min += $1 if $s =~ /(\d+)M/;

    return $min;
}

###########################################
sub jabber_send {
###########################################
    my($message) = @_;

    my $m = Net::Jabber::Message->new();
    my $jid = "$JABBER_ID" . '@' .
              "$JABBER_SERVER/".$config->param(-block=>'jabber')->{other_resource};

    $m->SetBody($message);
    $m->SetTo($jid);
    #DEBUG "Jabber to $jid: $message";
    my $rc = $c->Send($m, 1);

}
