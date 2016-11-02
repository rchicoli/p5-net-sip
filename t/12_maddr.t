#!/usr/bin/perl

###########################################################################
# creates a UAC and a UAS using Net::SIP::Simple
# and makes call from UAC to UAS,
# Call does not involve transfer of RTP data
###########################################################################

use strict;
use warnings;
use Test::More tests => 8*4;

do './testlib.pl' || do './t/testlib.pl' || die "no testlib";

use Net::SIP;
use Net::SIP::Util ':all';
use IO::Socket;

my @tests;
for my $transport (qw(udp tcp)) {
    for my $family (qw(ip4 ip6)) {
	push @tests, [ $transport, $family ];
    }
}

for my $t (@tests) {
    my ($transport,$family) = @$t;
    SKIP: {
	if (!use_ipv6($family eq 'ip6')) {
	    skip "no IPv6 support",8;
	    next;
	}

	note("------- test with family $family transport $transport");

	# create leg for UAS on dynamic port
	my ($sock_uas,$uas_addr) = create_socket($transport);
	ok( $sock_uas, 'create UAS socket' );

	# fork UAS and make call from UAC to UAS
	pipe( my $read,my $write); # to sync UAC with UAS
	my $pid = fork();
	if ( defined($pid) && $pid == 0 ) {
	    close($read);
	    $write->autoflush;
	    uas( $sock_uas, $write );
	    exit(0);
	}

	ok( $pid, "fork successful" );
	close( $sock_uas );
	close($write);

	alarm(15);
	$SIG{__DIE__} = $SIG{ALRM} = sub { kill 9,$pid; ok( 0,'died' ) };

	my $uas_uri = sip_parts2uri($uas_addr, undef, 'sip', {
	    $transport eq 'tcp' ? ( transport => 'tcp' ) :()
	});
	uac( $uas_uri,$read );

	ok( <$read>, "UAS finished" );
	wait;
    }
}

###############################################
# UAC
###############################################

sub uac {
    my ($peer_uri,$pipe) = @_;
    Net::SIP::Debug->set_prefix( "DEBUG(uac):" );

    ok( <$pipe>, "UAS created\n" ); # wait until UAS is ready
    my ($transport, $peer_addr, $peer_port)
	= sip_uri2sockinfo($peer_uri);
    my $uac = Net::SIP::Simple->new(
	from => 'me.uac@example.com',
	leg => (create_socket($transport))[0],
    );
    ok( $uac, 'UAC created' );

    ok( <$pipe>, "UAS ready\n" ); # wait until UAS is ready
    my $ringing = 0;
    my $call = $uac->invite(
	"<sip:you.uas\@example.com:$peer_port;maddr=$peer_addr>",
    );
    my $stop;
    if ( $call ) {
	ok( $call, 'Call established' );
	$call->loop(1);
	$call->bye( cb_final => \$stop );
	$call->loop( \$stop,10 );
    }
    ok( $stop, 'UAS down' );
}

###############################################
# UAS
###############################################

sub uas {
    my ($sock,$pipe) = @_;
    Net::SIP::Debug->set_prefix( "DEBUG(uas):" );
    my $uas = Net::SIP::Simple->new(
	domain => 'example.com',
	leg => $sock
    ) || die $!;
    print $pipe "UAS created\n";

    # Listen
    my $call_closed;
    $uas->listen(
	cb_established => sub { diag( 'call established' ) },
	cb_cleanup     => sub {
	    diag( 'call cleaned up' );
	    $call_closed =1;
	},
    );

    # notify UAC process that I'm listening
    print $pipe "UAS ready\n";

    # Loop until call is closed, at most 10 seconds
    $uas->loop( \$call_closed, 10 );

    # done
    if ( $call_closed ) {
	print $pipe "UAS finished\n";
    } else {
	print $pipe "call closed by timeout not stopvar\n";
    }
}
