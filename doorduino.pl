#!/usr/bin/perl -w
use strict;
use POSIX qw(strftime tcflush TCIFLUSH);
use IO::Socket::INET ();
use IO::Handle ();
use Sys::Syslog qw(openlog syslog :macros);


sub slurp ($) { local (@ARGV, $/) = @_; <>; }

my $hexchar = "0-9A-Fa-f";

use Digest::SHA qw(sha1_hex sha1);

my $dev = shift or die "Usage: $0 /dev/ttyUSBx";
(my $devname) = $dev =~ m{ ([^/]+) $ }x;
my $ircname = slurp "ircname.$devname";
chomp $ircname;

$ircname ||= $devname;


sub ibutton_digest {
    my ($id, $secret, $data, $challenge) = @_;

    $id        =~ /^[0-9A-Fa-f]{16}$/ or warn "Invalid ID ($id)";
    $secret    =~ /^[0-9A-Fa-f]{16}$/ or warn "Invalid secret ($secret)";
    $data      =~ /^[0-9A-Fa-f]{64}$/ or warn "Invalid data ($data)";
    $challenge =~ /^[0-9A-Fa-f]{6}$/  or warn "Invalid challenge ($challenge)";

    my @H01 = (  # Magische waardes uit NIST 180-1 (SHA1 specificatie)
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    );

    return uc unpack "H*", reverse join "", map {
        my $n = $_ - shift @H01;
	# Handmatig want pack N voor negatieve getallen blijtk stuk op perl+arm
        pack "N", $n >= 0 ? $n : (0xFFFFFFFF + $n + 1)
    } unpack "N*", sha1( pack "H*", join "",
        substr($secret, 0, 8),
        $data,
        "FFFFFFFF",
        "40",  # Wat is deze?
        substr($id, 0, 14),   # zonder checksum
        substr($secret, 8, 8),
        $challenge
    );
}

sub flush {
    my ($fh) = @_;
    sleep 1;
    tcflush(fileno($fh), TCIFLUSH);
}

openlog "doorduino", "nofatal,perror", LOG_USER;
sub logline { syslog LOG_INFO, "@_"; }

sub access {
    my ($out, $descr) = @_;

    logline "Access granted for $descr.\n";
    print {$out} "A\n";
    my $barsay = IO::Socket::INET->new(
        qw(PeerAddr 10.42.42.1  PeerPort 64123  Proto tcp)
    );
    $barsay->print("$ircname unlocked by $descr") if $barsay;
    flush($out);
}

system qw(stty -F), $dev, qw(cs8 57600 ignbrk -brkint -icrnl -imaxbel -opost
	-onlcr -isig -icanon -iexten -echo -echoe -echok -echoctl -echoke
	noflsh -ixon -crtscts);

open my $in,  "<", $dev or die $!;
open my $out, ">", $dev or die $!;

my $line;
my $id;
my $descr;
my $secret;
my $challenge;

for (;;) {
    sysread($in, my $char, 1) or next;
    $line .= $char;
    $line =~ /\n$/ or next;

    my $input = $line;
    $line = "";

    logline "Arduino says: $input";

    if ($input =~ /<([$hexchar]{64}) ([$hexchar]{40})>/) {
        my ($data, $response) = ($1, $2);
        my $expected = ibutton_digest($id, $secret, $data, $challenge);
        if (uc $response eq uc $expected) {
            access($out, $descr);
        } else {
            logline "Invalid response for challenge. Access denied.";
            print {$out} "N\n";
        }
        next;
    } elsif ($input =~ /<(BUTTON|\w{16})>/) {
        $id = $1;
    } else {
        next;
    }

    my $known = join "\n", map slurp($_), glob "ibuttons.acl.d/*.acl";
    my $valid = ($secret, $descr)
        = $known =~ /^$id(?::([$hexchar]{16}))?(?:\s+([^\r\n]+))?/mi;

    if ($valid and $secret) {
        $challenge = join "", map chr rand 256, 1..3;
        print {$out} "C$challenge\n";
        $challenge = unpack "H*", $challenge;

        logline "Initiating challenge/response for $descr";
    } elsif ($valid) {
        $id = "";
        $challenge = "";

        access($out, $descr);

    } else {
        $id = "";
        $challenge = "";

        logline "Access denied.\n";
	flush($out);
        print {$out} "N\n";
    }
}

