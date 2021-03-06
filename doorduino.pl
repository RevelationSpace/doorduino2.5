#!/usr/bin/perl -w
use strict;
use POSIX qw(strftime tcflush TCIFLUSH);
use IO::Handle ();
use Sys::Syslog qw(openlog syslog :macros);
use Time::HiRes qw(time sleep);

my $MAX_FAILURES = 20;
my $MAX_WRONG_RESPONSES = 3;
my $TIMEOUT = 2;  # reset state after n seconds of silence

sub slurp         { local (@ARGV, $/) = @_; <>; }
sub random_string { join "", map chr int rand 256, 1..shift }
sub hex_string    { unpack "H*", shift }
sub unhex         { pack "H*", shift }

my $hexchar = "0-9A-Fa-f";

use Digest::SHA qw(sha1_hex sha1);

my $conf_name = shift or die "Usage: $0 foo";

my $conf_file = -e $conf_name ? $conf_name : "$conf_name.conf.pl";
-r $conf_file or die "Cannot read $conf_file";
my %conf = do { local @INC = ("./"); do $conf_file; };

my $ircname = $conf{ircname} || $conf_name;
s/\.conf\.pl$// for $ircname, $conf_name;

openlog "doorduino\@$conf_name", -t STDIN ? "nofatal,perror" : "nofatal", LOG_USER;

my $dev = $conf{dev} or die "No dev in $conf_file";
-w $dev or die "$dev is not writable";

my $acldir = $conf{acldir} // "ibuttons.acl.d";
-d $acldir or die "$acldir is not a directory";

sub ibutton_sha1 {
    my $data = join "", @_;

    my @H01 = (  # Magische waardes uit NIST 180-1 (SHA1 specificatie)
        0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0
    );

    return scalar reverse join "", map {
        my $n = $_ - shift @H01;
	# Handmatig want pack N voor negatieve getallen blijtk stuk op perl+arm
        pack "N", $n >= 0 ? $n : (0xFFFFFFFF + $n + 1)
    } unpack "N*", sha1($data);
}

sub read_mac {
    my ($id, $secret, $page, $data, $challenge) = @_;

    $_ = unhex($_) for $id, $secret;

    return ibutton_sha1(
        substr($secret, 0, 4),
        $data,
        "\xFF\xFF\xFF\xFF",
        "\x40" | $page,
        substr($id, 0, 7),   # zonder checksum
        substr($secret, 4, 4),
        $challenge
    );
}

sub write_mac {
    my ($id, $secret, $page, $data, $newdata) = @_;

    $_ = unhex($_) for $id, $secret;

    return ibutton_sha1(
        substr($secret, 0, 4),
        substr($data, 0, 28),
        $newdata,
        $page,
        substr($id, 0, 7),   # zonder checksum
        substr($secret, 4, 4),
        "\xFF\xFF\xFF"
    );
}

sub flush {
    my ($fh) = @_;
    sleep .1;
    tcflush(fileno($fh), TCIFLUSH);
}

sub loginfo { 
    syslog LOG_INFO, "@_" if not $ENV{DOORDUINO_NOSYSLOG};
    print "@_\n"          if     $ENV{DOORDUINO_NOSYSLOG} or $ENV{DOORDUINO_DEBUG};
}

sub logerror { 
    syslog LOG_ERR, "@_" if not $ENV{DOORDUINO_NOSYSLOG};
    warn "@_\n"          if     $ENV{DOORDUINO_NOSYSLOG} or $ENV{DOORDUINO_DEBUG};
}

system qw(stty -F), $dev, qw(cs8 115200 ignbrk -brkint -icrnl -imaxbel -opost
        -onlcr -isig -icanon min 1 time 0 -iexten -echo -echoe -echok -echoctl
        -echoke noflsh -ixon -crtscts);

open my $in,  "<", $dev or die $!;
open my $out, ">", $dev or die $!;

sub access {
    my ($id, $name, $reason) = @_;

    local $ENV{DOORDUINO_IRCNAME} = $ircname;
    local $ENV{DOORDUINO_NAME} = $name;
    local $ENV{DOORDUINO_REASON} = $reason;
    local $ENV{DOORDUINO_ID} = $id;

    if ($conf{skip_access}) {
        loginfo "Access command not sent to doorduino (skip_access is active).";
    } else {
        if ($conf{verify_fail_locked}) {
            # Deny access if the program exits with anything but 0,
            # allow access only if the program exited cleanly.
            my $exitval = system "timeout", 2, $conf{verify_fail_locked};
            $exitval >>= 8 if $exitval;
            if ($exitval != 0) {
                no_access($id, $name, "verification script exited with $exitval");
                return;
            }
        }

        if ($conf{verify_fail_open}) {
            # Deny access if the program exits with 77 (sysexits.h EX_NOPERM)
            # but allow access if the program exits with any other status.
            my $exitval = system "timeout", 2, $conf{verify_fail_open};
            $exitval >>= 8 if $exitval;
            if ($exitval == 77) {
                no_access($id, $name, "verification script exited with $exitval");
                return;
            } elsif ($exitval) {
                loginfo("Verification script exited with $exitval; ignoring");
            }
        }

        loginfo "Access granted for $name, $reason.\n";
        print {$out} "A\n";
    }

    system "timeout", 5, "run-parts", "granted.d";
    sleep 2 if $conf{skip_access};  # debounce not done by doorduino in this case

    flush($out);
}

sub no_access {
    my ($id, $name, $reason) = @_;

    loginfo "Access denied for $name, $reason.\n";
    print {$out} "N\n";

    local $ENV{DOORDUINO_IRCNAME} = $ircname;
    local $ENV{DOORDUINO_NAME} = $name;
    local $ENV{DOORDUINO_REASON} = $reason;
    local $ENV{DOORDUINO_ID} = $id;
    system "timeout", 5, "run-parts", "denied.d";
    flush($out);
}

# state
my $line;
my $id;
my $name;
my $secret;
my $page;
my $challenge;
my $expected_response;
my $failures = 0;
my $attempts = 0;  # currently, only initial challenge/response is retried

sub reset_state {
    for ($id, $name, $secret, $page, $challenge, $expected_response) {
        undef $_;
    }
    $failures = 0;
}

my $last_k;
$SIG{ALRM} = sub {
    if ($last_k and time() - $last_k > 1) {
        logerror "Serial connection lost.";
    }
    print {$out} "K\n";
    $last_k = time;
};  # keepalive

print {$out} "K\n";

my $last_input = 0;

for (;;) {
    alarm 3;
    sysread($in, my $char, 1) or next;
    alarm 0;

    $line .= $char;
    $line =~ s/[\r\n]$// or next;

    my $input = $line;
    $line = "";

    length $input or next;

    if ($input =~ /<K>/) {
        warn strftime("%F %T Keepalive received.\n", localtime) if -t STDIN;
        $last_k = 0;
        next;
    }

    reset_state if time() >= $last_input + $TIMEOUT;
    $last_input = time;

    loginfo "Arduino says: $input";

    if ($expected_response and $input eq $expected_response) {
        access($id, $name, "after extended challenge/response");
        reset_state();
        next;
    } elsif ($input =~ /<([$hexchar]{64}) ([$hexchar]{40})>/) {
        my ($data, $mac) = (unhex($1), unhex($2));

        if (not $challenge) {
            # We've been here before.
            no_access($id, $name, "invalid response for extended challenge");
            reset_state();
            next;
        }

        my $wanted = read_mac($id, $secret, $page, $data, $challenge);

        if (uc $mac ne uc $wanted) {
            if (++$attempts >= $MAX_WRONG_RESPONSES) {
                no_access($id, $name, "invalid response for initial challenge");
                reset_state();
                next;
            } else {
                loginfo "Initiating challenge/response for $name (attempt $attempts)";
                $page = chr int rand 4;
                $challenge = random_string(3);
                print {$out} "C$page$challenge\n";
                next;
            }
        }

        undef $challenge;

        loginfo "Initiating extended challenge/response for $name.";

        my $newdata     = random_string(8);
        my $offset      = 8 * int rand 4;
        my $auth        = write_mac($id, $secret, $page, $data, $newdata);
        my $rechallenge = random_string(3);

        substr $data, $offset, 8, $newdata;

        $expected_response = uc sprintf "<%s %s>", (
            hex_string($data),
            hex_string(read_mac($id, $secret, $page, $data, $rechallenge))
        );

        print {$out} "X", $page, $rechallenge, chr($offset), $newdata, $auth, "\n"
    } elsif ($input =~ /<(BUTTON|\w{16})>/) {
        $id = $1;

        my $known = join "\n", map slurp($_), glob "$acldir/*.acl";

        my $valid = ($secret, $name)
            = $known =~ m[^
                $id
                (?: :      ( [$hexchar]{16} ))?
                (?: [ \t]+ ( [^\r\n]+ ))?
            ]mix;

        if ($valid and $secret) {
            loginfo "Initiating challenge/response for $name";
            $attempts = 0;
            $page = chr int rand 4;
            $challenge = random_string(3);
            print {$out} "C$page$challenge\n";
        } elsif ($valid and $id eq 'BUTTON') {
            access($id, $name, "button access allowed in ACL");
            reset_state();
        } elsif ($valid and $conf{allow_insecure}) {
            access($id, $name, "without challenge/response");
            reset_state();
        } elsif ($valid) {
            no_access($id, $name, "ID-only access is disabled");
            reset_state();
        } else {
            no_access($id, $id, "because it is unlisted");
            reset_state();
        }
    } else {
        # Unknown data from arduino; assume it's an error message.
        $failures++;
        if ($failures > $MAX_FAILURES) {
            no_access("UNKNOWN", "Unknown", "because of repeated failures");
            reset_state();
        }
    }
}

