use strict;
use warnings;
use experimental 'smartmatch';

use Irssi::TextUI;
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

# Enable for debugging purposes only.
# use Data::Dumper;

our $VERSION = '1.00';
our %IRSSI = (
    name        => 'is-pd-bot',
    description => 'Colours from Mattermost is-pd-bot and things',
    authors     => 'Haw Loeung',
    contact     => 'hloeung/Freenode',
    license     => 'GPL',
);

settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');
settings_add_str('is_pd_bot', 'is_pd_bot_nick', 'is-pd-bot');
settings_add_str('is_pd_bot', 'is_pd_bot_pagerduty_channel', 'is-pagerduty');
settings_add_str('is_pd_bot', 'is_pd_bot_outage_channel', 'is-outage');
# Noisy bots sharing the same outage channel.
settings_add_str('is_pd_bot', 'is_pd_bot_noisy_bots', 'webbot');

my $pd_url = 'https://canonical.pagerduty.com/incidents/';

my @PD_CACHE;
settings_add_int('is_pd_bot', 'pagerduty_cache_size', 20);
command_bind 'pagerduty_cache_dump' => sub {
    my ($data, $server, $wi) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (scalar(@PD_CACHE) == 0) {
        Irssi::print('Empty PagerDuty incidents in cache, see ' . $pd_url);
    }
    foreach my $pd_id (@PD_CACHE) {
        Irssi::print($pd_id . ' - ' . $pd_url . $pd_id);
    }
};

my $PD_CACHE_INDEX = 0;

signal_add_last 'message public' => sub {
    my($server, $msg, $nick, $address, $target) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    my $pagerduty_channel = '#' . settings_get_str('is_pd_bot_pagerduty_channel');
    my $outage_channel = '#' . settings_get_str('is_pd_bot_outage_channel');
    return unless ($target ne $pagerduty_channel) || ($target ne $outage_channel);

    my $bot_nick = settings_get_str('is_pd_bot_nick');
    my @noisy_bots = split(/\s+/, settings_get_str('is_pd_bot_noisy_bots'));

    if (($target eq $pagerduty_channel) && ($nick eq $bot_nick)) {
        my $pd_id;

        if ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*🆗 ACKNOWLEDGED\*\*/$1 \x02\x0307🆗 ACKNOWLEDGED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*🚨 TRIGGERED\*\*/$1 \x02\x0304🚨 TRIGGERED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*✅ RESOLVED\*\*/$1 \x02\x0303✅ RESOLVED\x0f/) {
            my $resolved_id = $2;
            # Clean up resolved PagerDuty incident from cache.
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $resolved_id)) {
                    splice(@PD_CACHE, $i, 1);
                }
            }
            $pd_id = '';
        }

        elsif ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*‼️ UNACKNOWLEDGED\*\*/$1 \x02\x0304‼️  UNACKNOWLEDGED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*📤 ESCALATED\*\*/$1 \x02\x0306📤 ESCALATED\x0f/) {
            $pd_id = $2;
        }

        elsif ($msg =~ s/^(?:\[\d{2}:\d{2}\] )?((?:\[(?:@@)?\w+\] )?(P\w{6})) \*\*📥 ASSIGNED\*\*/$1 \x02\x0308📥 ASSIGNED\x0f/) {
            $pd_id = $2;
        }

        if ($pd_id) {
            # Reset search index on changes.
            if ($PD_CACHE[0] && ($PD_CACHE[0] ne $pd_id)) {
                $PD_CACHE_INDEX = 0;
            }

            # Make sure it doesn't already exist in the cache.
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $pd_id)) {
                    splice(@PD_CACHE, $i, 1);
                }
            }
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

    elsif ($target eq $outage_channel) {
        # We can't match on begin with (^) so threaded replies are
        # also colourised.
        $msg =~ s/🚨 Incident/\x02\x0307🚨\x0f Incident/;
        $msg =~ s/✅ Incident/\x02\x0303✅\x0f Incident/;
        if ($nick eq $bot_nick) {
            $msg =~ s/taking a look\./\x02\x0307taking a look\x0f./;
            $msg =~ s/now resolved\./\x02\x0303now resolved\x0f./;
        }

        elsif ($nick ~~ @noisy_bots) {
            $msg =~ s/^\[/\x0314[/;
        }
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_ADDED = 0;
command_bind 'pagerduty_cache_search' => sub {
    my ($data, $server, $wi) = @_;

    my $pagerduty_channel = '#' . settings_get_str('is_pd_bot_pagerduty_channel');
    return unless ref $wi and ($wi->{type} eq 'CHANNEL' and $wi->{name} eq $pagerduty_channel);

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
my $KEY_CTRL_U = 21;
my $KEY_ESC    = 27;
my $KEY_RET    = 13;
my $KEY_SPC    = 32;

signal_add_last 'gui key pressed' => sub {
    my ($key) = @_;

    return unless $PD_CACHE_SEARCH_ENABLED;

    my $server = Irssi::active_server();
    my %chatnets = map { $_ => 1 } split(/\s+/, settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (($key == $KEY_RET) || ($key == $KEY_CTRL_U)) {
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
