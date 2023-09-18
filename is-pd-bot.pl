use strict;
use warnings;
use experimental 'smartmatch';

require Irssi::TextUI;
require Irssi;

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

Irssi::settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_nick', 'is-pd-bot');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_pagerduty_channel', 'is-pagerduty');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_outage_channel', 'is-outage');
# Noisy bots sharing the same outage channel.
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_noisy_bots', 'webbot');

my $pd_url = 'https://canonical.pagerduty.com/incidents/';

my @PD_CACHE;
Irssi::settings_add_int('is_pd_bot', 'pagerduty_cache_size', 20);
sub cmd_pagerduty_cache_dump {
    my ($data, $server, $wi) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, Irssi::settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    if (scalar(@PD_CACHE) == 0) {
        Irssi::print('Empty PagerDuty incidents in cache, see ' . $pd_url);
    }
    foreach my $pd_id (@PD_CACHE) {
        Irssi::print($pd_id . ' - ' . $pd_url . $pd_id);
    }
};
Irssi::command_bind('pagerduty_cache_dump', 'cmd_pagerduty_cache_dump');

my $PD_CACHE_INDEX = 0;

sub signal_message_public {
    my($server, $msg, $nick, $address, $target) = @_;

    my %chatnets = map { $_ => 1 } split(/\s+/, Irssi::settings_get_str('matterircd_complete_networks'));
    return unless exists $chatnets{'*'} || exists $chatnets{$server->{chatnet}};

    my $pagerduty_channel = '#' . Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    my $outage_channel = '#' . Irssi::settings_get_str('is_pd_bot_outage_channel');
    return unless ($target ne $pagerduty_channel) || ($target ne $outage_channel);

    my $bot_nick = Irssi::settings_get_str('is_pd_bot_nick');
    my @noisy_bots = split(/\s+/, Irssi::settings_get_str('is_pd_bot_noisy_bots'));

    if (($target eq $pagerduty_channel) && ($nick eq $bot_nick)) {
        my $pd_id;

        if ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)🆗 ACKNOWLEDGED(\*\*|\x02)/$1 \x02\x0307🆗 ACKNOWLEDGED\x0f/) {
            $pd_id = $1;
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*\*|\x1d)🚨 TRIGGERED(\*\*\*|\x1d)/\x02$1 \x0304🚨 TRIGGERED\x0f/) {
            $pd_id = $1;
        }
        # Backwards compatibility
        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)🚨 TRIGGERED(\*\*|\x02)/\x02$1 \x0304🚨 TRIGGERED\x0f/) {
            $pd_id = $1;
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)✅ RESOLVED(\*\*|\x02)/$1 \x02\x0303✅ RESOLVED\x0f/) {
            my $resolved_id = $1;
            # Clean up resolved PagerDuty incident from cache.
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $resolved_id)) {
                    splice(@PD_CACHE, $i, 1);
                }
            }
            $pd_id = '';
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)‼️ UNACKNOWLEDGED(\*\*|\x02)/\x02$1 \x0304‼️  UNACKNOWLEDGED\x0f/) {
            $pd_id = $1;
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)📤 ESCALATED(\*\*|\x02)/$1 \x02\x0306📤 ESCALATED\x0f/) {
            $pd_id = $1;
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)📥 REASSIGNED(\*\*|\x02)/$1 \x02\x0308📥 REASSIGNED\x0f/) {
            $pd_id = $1;
        }

        elsif ($msg =~ s/(P\w{6}|Q\w{13}) (\*\*|\x02)💤 SNOOZED(\*\*|\x02)/$1 \x02\x0312💤 SNOOZED\x0f/) {
            $pd_id = $1;
        }

        else {
            # '**P3WQTNO** **PB5U6D4** **P3F46SI**' becomes 'P3WQTNO PB5U6D4 P3F46SI'
            # so we can easily just copy the entire list of
            # outstanding incidents and ack.
            $msg =~ s/(?:\*\*\*|\x1d)(P\w{6}|Q\w{13})(?:\*\*\*|\x1d)/\x02\x0304$1\x0f/g;
            $msg =~ s/(?:\*\*|\x02)(P\w{6}|Q\w{13})(?:\*\*|\x02)/\x02\x0307$1\x0f/g;
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
            unshift(@PD_CACHE, $pd_id);
            # Remove last seen PagerDuty incidents if reached
            # max. cache size.
            if (scalar(@PD_CACHE) > Irssi::settings_get_int('pagerduty_cache_size')) {
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
Irssi::signal_add_last('message public', 'signal_message_public');

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_ADDED = 0;
sub cmd_pagerduty_cache_search {
    my ($data, $server, $wi) = @_;

    my $pagerduty_channel = '#' . Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    return unless ref $wi and ($wi->{type} eq 'CHANNEL' and $wi->{name} eq $pagerduty_channel);

    my %chatnets = map { $_ => 1 } split(/\s+/, Irssi::settings_get_str('matterircd_complete_networks'));
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
        $input =~ s/(P\w{6}|Q\w{13})$//;

        # Insert PagerDuty incident from cache.
        gui_input_set_pos(0);
        gui_input_set($input . $pd_id);

        $PD_ADDED = 1;
    }
};
Irssi::command_bind('pagerduty_cache_search', 'cmd_pagerduty_cache_search');

my $KEY_CTRL_C = 3;
my $KEY_CTRL_U = 21;
my $KEY_ESC    = 27;
my $KEY_RET    = 13;
my $KEY_SPC    = 32;

sub signal_gui_key_pressed {
    my ($key) = @_;

    return unless $PD_CACHE_SEARCH_ENABLED;

    my $server = Irssi::active_server();
    my %chatnets = map { $_ => 1 } split(/\s+/, Irssi::settings_get_str('matterircd_complete_networks'));
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
            if ($input =~ s/(P\w{6}|Q\w{13})$//) {
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
Irssi::signal_add_last('gui key pressed', 'signal_gui_key_pressed');
