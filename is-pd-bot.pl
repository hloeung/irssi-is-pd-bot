use strict;
use warnings;
use experimental 'smartmatch';

use Irssi qw(
    command_bind
    gui_input_get_pos
    gui_input_set_pos
    gui_input_set
    parse_special
    settings_add_int
    settings_add_str
    settings_get_int
    settings_get_str
    signal_add_last
);


our $VERSION = '1.00';
our %IRSSI = (
    name        => 'is-pd-bot',
    description => 'Colours from Mattermost is-pd-bot and things',
    authors     => 'Haw Loeung',
    contact     => 'hloeung/Freenode',
    license     => 'GPL',
);

settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');

my @PD_CACHE;
settings_add_int('is_pd_bot', 'pagerduty_cache_size', 20);
command_bind 'pagerduty_cache_dump' => sub {
    my ($data, $server, $wi) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (scalar(@PD_CACHE) == 0) {
        Irssi::print('Empty PagerDuty incidents cache');
    }
    foreach my $pd_id (@PD_CACHE) {
        Irssi::print($pd_id);
    }
};

signal_add_last 'message public' => sub {
    my($server, $msg, $nick, $address, $target) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (($target eq '#is-pagerduty') && ($nick eq 'is-pd-bot')) {
        my $pd_id;

        if ($msg =~ s/^((?:\[(?:@@)?\w+\] )?P\w{6}) \*\*🆗 ACKNOWLEDGED\*\*/$1 \x02\x0307🆗 ACKNOWLEDGED\x0f/) {
            $pd_id = '';
        }

        elsif ($msg =~ s/^((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*🚨 TRIGGERED\*\*/$1 \x02\x0304🚨 TRIGGERED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*✅ RESOLVED\*\*/$1 \x02\x0303✅ RESOLVED\x0f/) {
            my $resolved_id = $2;
            # Clean up resolved PagerDuty incident from cache.
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $resolved_id)) {
                    splice(@PD_CACHE, $i, 1);
                }
            }
            $pd_id = '';
        }

        elsif ($msg =~ s/^((?:\[(?:@@)?\w+\] )?P\w{6}) \*\*‼️ UNACKNOWLEDGED\*\*/$1 \x02\x0304‼️  UNACKNOWLEDGED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*📤 ESCALATED\*\*/$1 \x02\x0306📤 ESCALATED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^((?:\[(?:@@)?\w+\] )?P\w{6}) \*\*📥 ASSIGNED\*\*/$1 \x02\x0308📥 ASSIGNED\x0f/) {
            $pd_id = '';
        }

        if ($pd_id) {
            # Store most recently seen PagerDuty incidents at the
            # start.
            unshift(@PD_CACHE, $2);
            # Remove last seen PagerDuty incidents if reached
            # max. cache size.
            if (scalar(@PD_CACHE) > settings_get_int('pagerduty_cache_size')) {
                pop(@PD_CACHE);
            }
        }
    }

    # webbot noise
    elsif ($nick eq 'webbot') {
        $msg =~ s/^\[/\x0314[/;
    }

    elsif (($target eq '#is-outage') && ($nick eq 'is-pd-bot')) {
        $msg =~ s/^✅ Incident/\x02\x0303✅\x0f Incident/;
        $msg =~ s/now resolved\./\x02\x0303now resolved\x0f./;
        $msg =~ s/^🚨 Incident/\x02\x0307🚨\x0f Incident/;
        $msg =~ s/taking a look\./\x02\x0307taking a look\x0f./;
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_CACHE_INDEX = 0;
my $PD_ADDED = 0;
command_bind 'pagerduty_cache_search' => sub {
    my ($data, $server, $wi) = @_;

    return unless ref $wi and ($wi->{type} eq 'CHANNEL' and $wi->{name} eq '#is-pagerduty');

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    $PD_CACHE_SEARCH_ENABLED = 1;
    my $pd_id = $PD_CACHE[$PD_CACHE_INDEX];
    $PD_CACHE_INDEX += 1;
    if ($PD_CACHE_INDEX > $#PD_CACHE) {
        # Cycle back to the start.
        $PD_CACHE_INDEX = 0;
    }

    if ($pd_id) {
        # Save input text.
        my $input = parse_special('$L');
        # Remove previously inserted PagerDuty incident.
        $input =~ s/P\w{6}$//;

        # Insert PagerDuty incident from cache.
        gui_input_set_pos(0);
        gui_input_set($input . $pd_id);

        $PD_ADDED = 1;
    }
};

my $KEY_CTRL_C = 3;
my $KEY_ESC    = 27;
my $KEY_RET    = 13;
my $KEY_SPC    = 32;

signal_add_last 'gui key pressed' => sub {
    my ($key) = @_;

    return unless $PD_CACHE_SEARCH_ENABLED;

    my $server = Irssi::active_server();
    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if ($key == $KEY_RET) {
        $PD_ADDED = 0;
        $PD_CACHE_INDEX = 0;
        $PD_CACHE_SEARCH_ENABLED = 0;
    }

    # Cancel/abort.
    elsif ($key == $KEY_CTRL_C) {
        my $input = parse_special('$L');

        # Remove the Ctrl+C character.
        $input =~ tr///d;

        if ($PD_ADDED) {
            my $pos = gui_input_get_pos();
            if ($input =~ s/P\w{6}$//) {
                $pos -= 7;
            }

            # We also want to move the input position back one for
            # Ctrl+C char.
            $pos = $pos > 0 ? $pos - 1 : 0;

            # Replace the text in the input box with our modified
            # version, then move cursor positon to where it was
            # without the inserted PagerDuty incident.
            gui_input_set($input);
            gui_input_set_pos($pos);
        }

        $PD_ADDED = 0;
        $PD_CACHE_INDEX = 0;
        $PD_CACHE_SEARCH_ENABLED = 0;
    }
};
