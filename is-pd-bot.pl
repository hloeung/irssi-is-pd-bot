use strict;
use warnings;
use experimental 'smartmatch';

require Irssi::TextUI;
require Irssi;

# Enable for debugging purposes only.
# use Data::Dumper;

our $VERSION = '2.00';
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
# Noisy bots sharing the same outage channel.
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_noisy_bots', 'webbot');

my $pd_url = 'https://canonical.pagerduty.com/incidents/';

# Cached chatnet check (from matterircd_complete.pl)
my $CHATNETS_RAW;
my %CHATNETS;

sub chatnet_enabled {
    my ($server_or_chatnet) = @_;
    return 0 unless defined $server_or_chatnet;

    if (!defined($CHATNETS_RAW)) {
        $CHATNETS_RAW = Irssi::settings_get_str('matterircd_complete_networks');
        %CHATNETS = map { lc($_) => 1 } split(/\s+/, $CHATNETS_RAW);
    }
    return 1 if exists $CHATNETS{'*'};

    if (ref($server_or_chatnet)) {
        return 1 if defined $server_or_chatnet->{chatnet} && exists $CHATNETS{lc($server_or_chatnet->{chatnet})};
        return 1 if defined $server_or_chatnet->{tag}     && exists $CHATNETS{lc($server_or_chatnet->{tag})};
        return 0;
    }
    return exists $CHATNETS{lc($server_or_chatnet)};
}

Irssi::signal_add('setup changed', sub { $CHATNETS_RAW = undef; });
Irssi::signal_add('setup reread',  sub { $CHATNETS_RAW = undef; });

my @PD_CACHE;
my $PENDING_PD_ID;
Irssi::settings_add_int('is_pd_bot', 'pagerduty_cache_size', 20);
sub cmd_pagerduty_cache_dump {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);

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
    my ($server, $msg, $nick, $address, $target) = @_;

    return unless chatnet_enabled($server);

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless lc($target) eq lc($pagerduty_channel);

    my $bot_nick = Irssi::settings_get_str('is_pd_bot_nick');
    my @noisy_bots = split(/\s+/, Irssi::settings_get_str('is_pd_bot_noisy_bots'));

    if ((lc($target) eq lc($pagerduty_channel)) && (lc($nick) eq lc($bot_nick))) {
        my $pd_id;

        # Ordering matters, TRIGGERED can also be part of the
        # parent/thread msg. Ignore thread reply quotes so
        # quoted parent incidents don't re-enter the cache.
        my $clean_msg = $msg;
        $clean_msg =~ s/^\(re .*\@${bot_nick}: .*?\)\s*//;

        # Track pending incident ID from URL or table row across wrapped lines
        if ($clean_msg =~ /(?:incidents\/|[🮇\|]\s*|\b)(P\w{6}|Q\w{13})\b/ && $clean_msg !~ /Alert ID/) {
            $PENDING_PD_ID = $1;
        }

        # Clean up resolved PagerDuty incident from cache (same-line or wrapped table)
        if (($clean_msg =~ /(P\w{6}|Q\w{13})\s+.*✅ RESOLVED/) || ($PENDING_PD_ID && $clean_msg =~ /✅ RESOLVED/)) {
            my $resolved_id = $1 || $PENDING_PD_ID;
            $PENDING_PD_ID = undef;
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $resolved_id)) {
                    splice(@PD_CACHE, $i, 1);
                }
            }
        }
        # Match active PagerDuty incidents to populate cache (same-line or wrapped table)
        elsif (($clean_msg =~ /(P\w{6}|Q\w{13})\s+.*(?:🚨 TRIGGERED|🆗 ACKNOWLEDGED|‼ UNACKNOWLEDGED|📤 ESCALATED|📥 (?:RE)?ASSIGNED|💤 SNOOZED)/)
            || ($PENDING_PD_ID && $clean_msg =~ /(?:🚨 TRIGGERED|🆗 ACKNOWLEDGED|‼ UNACKNOWLEDGED|📤 ESCALATED|📥 (?:RE)?ASSIGNED|💤 SNOOZED)/)) {
            $pd_id = $1 || $PENDING_PD_ID;
            $PENDING_PD_ID = undef;
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
            # Store most recently seen PagerDuty incidents at the start.
            unshift(@PD_CACHE, $pd_id);
            # Remove last seen PagerDuty incidents if reached max. cache size.
            if (scalar(@PD_CACHE) > Irssi::settings_get_int('pagerduty_cache_size')) {
                pop(@PD_CACHE);
            }
        }
    }

    else {
        return;
    }

    Irssi::signal_continue($server, $msg, $nick, $address, $target);
};
Irssi::signal_add_last('message public', 'signal_message_public');

# Tab auto-completion for PagerDuty incident IDs in cache
sub signal_complete_word_pagerduty {
    my ($complist, $window, $word, $linestart, $want_space) = @_;

    return unless chatnet_enabled($window->{active_server});
    return unless $window->{active} && $window->{active}->{type} eq 'CHANNEL';

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless lc($window->{active}->{name}) eq lc($pagerduty_channel);

    return unless $word =~ /^[PQ]/i;

    my %seen;
    foreach my $pd_id (@PD_CACHE) {
        next if $seen{$pd_id}++;
        push(@$complist, $pd_id) if index(uc($pd_id), uc($word)) == 0;
    }
}
Irssi::signal_add_last('complete word', 'signal_complete_word_pagerduty');

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_ADDED = 0;
sub cmd_pagerduty_cache_search {
    my ($data, $server, $wi) = @_;

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless ref $wi and ($wi->{type} eq 'CHANNEL' and lc($wi->{name}) eq lc($pagerduty_channel));

    return unless chatnet_enabled($server);

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
    return unless chatnet_enabled($server);

    if (($key == $KEY_RET) || ($key == $KEY_CTRL_U)) {
        $PD_ADDED = 0;
        $PD_CACHE_INDEX = 0;
        $PD_CACHE_SEARCH_ENABLED = 0;
    }

    # Cancel/abort.
    elsif ($key == $KEY_CTRL_C) {
        my $input = parse_special('$L');

        # Remove the Ctrl+C character.
        $input =~ tr/\x03//d;

        if ($PD_ADDED) {
            my $pos = gui_input_get_pos();
            if ($input =~ s/(P\w{6}|Q\w{13})$//) {
                # 7 chars for P-ids, 14 chars for Q-ids
                $pos -= length($1);
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
