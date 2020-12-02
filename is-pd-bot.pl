use strict;
use warnings;
use experimental 'smartmatch';

use Irssi qw(settings_add_str settings_get_str signal_add_last);


our $VERSION = '1.00';
our %IRSSI = (
    name        => 'is-pd-bot',
    description => 'Colours from mattermost is-pd-bot',
    authors     => 'Haw Loeung',
    contact     => 'hloeung/Freenode',
    license     => 'GPL',
);

settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');

signal_add_last 'message public' => sub {
    my($server, $msg, $nick, $address, $target) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (($target eq '#is-pagerduty') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*🆗 ACKNOWLEDGED\*\*/$1 \x02\x0307🆗 ACKNOWLEDGED\x0f/;
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*📥 ASSIGNED\*\*/$1 \x02\x0308📥 ASSIGNED\x0f/;
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*📤 ESCALATED\*\*/$1 \x02\x0306📤 ESCALATED\x0f/;
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*✅ RESOLVED\*\*/$1 \x02\x0303✅ RESOLVED\x0f/;
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*🚨 TRIGGERED\*\*/$1 \x02\x0304🚨 TRIGGERED\x0f/;
        $msg =~ s/^((?:\[(?:@@)?\w+\] )?\w{7}) \*\*‼️ UNACKNOWLEDGED\*\*/$1 \x02\x0304‼️  UNACKNOWLEDGED\x0f/;
    }

    # webbot noise
    elsif ($nick eq 'webbot') {
        $msg =~ s/^\[/\x0314[/;
    }

    elsif (($target eq '#is-outage') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/^✅ Incident/\x02\x0303✅\x0f Incident/;
        $msg =~ s/now resolved\.( \[(?:@@)?\w+\]\s*)?$/\x02\x0303now resolved\x0f.$1/;
        $msg =~ s/^🚨 Incident/\x02\x0307🚨\x0f Incident/;
        $msg =~ s/taking a look\.( \[(?:@@)?\w+\]\s*)?$/\x02\x0307taking a look\x0f.$1/;
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};
