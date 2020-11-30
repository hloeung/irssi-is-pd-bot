use strict;
use warnings;
use experimental 'smartmatch';

use Irssi qw(signal_add_last);


our $VERSION = '1.00';
our %IRSSI = (
    name        => 'is-pd-bot',
    description => 'Colours from mattermost is-pd-bot',
    authors     => 'Haw Loeung',
    contact     => 'hloeung/Freenode',
    license     => 'GPL',
);


signal_add_last 'message public' => sub {
    my($server, $msg, $nick, $address, $target) = @_;

    if (($target eq '#is-pagerduty') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/\*\*🆗 ACKNOWLEDGED\*\*/\x02\x0307🆗 ACKNOWLEDGED\x0f/g;
        $msg =~ s/\*\*📥 ASSIGNED\*\*/\x02\x0308📥 ASSIGNED\x0f/g;
        $msg =~ s/\*\*📤 ESCALATED\*\*/\x02\x0306📤 ESCALATED\x0f/g;
        $msg =~ s/\*\*✅ RESOLVED\*\*/\x02\x0303✅ RESOLVED\x0f/g;
        $msg =~ s/\*\*🚨 TRIGGERED\*\*/\x02\x0304🚨 TRIGGERED\x0f/g;
        $msg =~ s/\*\*‼️ UNACKNOWLEDGED\*\*/\x02\x0304‼️  UNACKNOWLEDGED\x0f/g;
    }

    # webbot noise
    elsif ($nick eq 'webbot') {
        $msg =~ s/\[/\x0314[/g;
    }

    elsif (($target eq '#is-outage') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/:white_check_mark: Incident/\x02\x0303✅\x0f Incident/g;
        $msg =~ s/now resolved\./\x02\x0303now resolved\x0f./g;
        $msg =~ s/:rotating_light: Incident/\x02\x0307🚨\x0f Incident/g;
        $msg =~ s/taking a look\./\x02\x0307taking a look\x0f./g;
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};
