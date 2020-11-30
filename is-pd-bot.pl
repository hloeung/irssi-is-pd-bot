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
        $msg =~ s/\*\*🆗 ACKNOWLEDGED\*\*/\x02\x0307🆗 ACKNOWLEDGED\x0f/;
        $msg =~ s/\*\*📥 ASSIGNED\*\*/\x02\x0308📥 ASSIGNED\x0f/;
        $msg =~ s/\*\*📤 ESCALATED\*\*/\x02\x0306📤 ESCALATED\x0f/;
        $msg =~ s/\*\*✅ RESOLVED\*\*/\x02\x0303✅ RESOLVED\x0f/;
        $msg =~ s/\*\*🚨 TRIGGERED\*\*/\x02\x0304🚨 TRIGGERED\x0f/;
        $msg =~ s/\*\*‼️ UNACKNOWLEDGED\*\*/\x02\x0304‼️  UNACKNOWLEDGED\x0f/;
    }

    # webbot noise
    elsif ($nick eq 'webbot') {
        $msg =~ s/\[/\x0314[/;
    }

    elsif (($target eq '#is-outage') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/:white_check_mark: Incident/\x02\x0303✅\x0f Incident/;
        $msg =~ s/now resolved\./\x02\x0303now resolved\x0f./;
        $msg =~ s/:rotating_light: Incident/\x02\x0307🚨\x0f Incident/;
        $msg =~ s/taking a look\./\x02\x0307taking a look\x0f./;
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};
