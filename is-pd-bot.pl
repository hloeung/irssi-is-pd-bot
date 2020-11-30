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


my $ENABLED = 0;

signal_add_last 'message public' => sub {
    my($server, $msg, $nick, $address, $target) = @_;

    if ($ENABLED) {
        Irssi::command('^format -reset pubmsg');
        Irssi::command('^format -reset pubmsg_hilight');
        $ENABLED = 0;
    }

    if (($target eq '#is-pagerduty') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/:ok: ACKNOWLEDGED/\x02\x0307🆗 ACKNOWLEDGED\x0f/g;
        $msg =~ s/:inbox_tray: ASSIGNED/\x02\x0308📥 ASSIGNED\x0f/g;
        $msg =~ s/:outbox_tray: ESCALATED/\x02\x0306📤 ESCALATED\x0f/g;
        $msg =~ s/:white_check_mark: RESOLVED/\x02\x0303✅ RESOLVED\x0f/g;
        $msg =~ s/:rotating_light: TRIGGERED/\x02\x0304🚨 TRIGGERED\x0f/g;
        $msg =~ s/:bangbang: UNACKNOWLEDGED/\x02\x0304‼️  UNACKNOWLEDGED\x0f/g;
    }

    # webbot noise
    elsif ($nick eq 'webbot') {
        $msg =~ s/\[/\x0314/g;
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

    $ENABLED = 1;
    # From src/fe-common/core/module-formats.c.
    Irssi::command('^format pubmsg {pubmsgnick $2 {pubnick $0}}' . $msg);
    Irssi::command('^format pubmsg_hilight {pubmsghinick $0 $3 $1}' . $msg);
};
