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

my $pd_url = 'https://canonical.pagerduty.com/incidents/';

Irssi::settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_nick', 'is-pd-bot');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_pagerduty_channel', 'is-pagerduty');
Irssi::settings_add_int('is_pd_bot', 'is_pd_bot_pagerduty_cache_size', 20);
Irssi::settings_add_int('is_pd_bot', 'pagerduty_cache_size', -1);

sub get_pagerduty_cache_size {
    my $legacy = Irssi::settings_get_int('pagerduty_cache_size');
    return $legacy if defined($legacy) && $legacy > 0;
    my $new    = Irssi::settings_get_int('is_pd_bot_pagerduty_cache_size');
    return (defined($new) && $new > 0) ? $new : 20;
}

# Migrate legacy setting if customized
my $legacy_cache_size = Irssi::settings_get_int('pagerduty_cache_size');
if ($legacy_cache_size > 0) {
    if (Irssi::settings_get_int('is_pd_bot_pagerduty_cache_size') == 20) {
        Irssi::settings_set_int('is_pd_bot_pagerduty_cache_size', $legacy_cache_size);
    }
    Irssi::settings_set_int('pagerduty_cache_size', -1);
}

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

sub _wi_print {
    my ($wi, $msg) = @_;
    if ($wi) {
        $wi->print($msg);
    } else {
        Irssi::print($msg);
    }
}

sub resolve_thread_id {
    my ($target, $id) = @_;
    return $id unless defined $id && length $id;
    $id =~ s/(?:…|\.\.\.)$//;
    if (defined &Irssi::Script::matterircd_complete::msgthreadid_find) {
        my $full = Irssi::Script::matterircd_complete::msgthreadid_find($target, $id);
        return $full if defined $full && length $full;
    } elsif (defined &Irssi::Script::Matterircd_Tab_Auto_Complete::msgthreadid_find) {
        my $full = Irssi::Script::Matterircd_Tab_Auto_Complete::msgthreadid_find($target, $id);
        return $full if defined $full && length $full;
    }
    return $id;
}

sub thread_color {
    my ($id) = @_;
    if (defined &Irssi::Script::matterircd_complete::thread_color) {
        return Irssi::Script::matterircd_complete::thread_color($id);
    } elsif (defined &Irssi::Script::Matterircd_Tab_Auto_Complete::thread_color) {
        return Irssi::Script::Matterircd_Tab_Auto_Complete::thread_color($id);
    }
    # Fallback deterministic mIRC color if matterircd_complete is unavailable
    my @colors = qw(03 04 06 07 09 10 11 12 13);
    my $n = 0;
    $n = ($n * 36 + ord($_)) % scalar(@colors) for split //, lc($id);
    return "\x03" . $colors[$n];
}

sub short_thread_id {
    my ($id) = @_;
    return $id unless defined $id && length $id;
    my $len = Irssi::settings_get_int('matterircd_complete_shorten_message_thread_id');
    $len = 5 if !defined($len) || $len <= 0;
    my $thread_m_style = ($id =~ /^[0-9a-f]{3}$/) ? 1 : 0;
    if (($len < 25) && ($thread_m_style != 1) && (length($id) > $len)) {
        return substr($id, 0, $len) . '…';
    }
    return $id;
}

my @PD_CACHE;
my %PENDING_PD_ID;
my %PENDING_TID;
my %THREAD_PD_MAP;
my %THREAD_PD_ORDER;
my %PD_STATUS;

sub is_canonical_tid {
    my ($tid) = @_;
    return 0 unless defined $tid && length $tid;
    return ($tid =~ /^[0-9a-z]{26}$/ || $tid =~ /^\$[0-9A-Za-z\-_\.]{43}$/ || $tid =~ /^[0-9a-f]{3}$/) ? 1 : 0;
}

sub is_pd_id_mapped {
    my ($id) = @_;
    return 0 unless defined $id;
    for my $server_map (values %THREAD_PD_MAP) {
        return 1 if grep { $_ eq $id } values %$server_map;
    }
    return 0;
}

sub is_thread_alias {
    my ($server_tag, $tid1, $tid2) = @_;
    return 1 if $tid1 eq $tid2;

    if (index($tid1, $tid2) == 0 || index($tid2, $tid1) == 0) {
        my $short = (length($tid1) < length($tid2)) ? $tid1 : $tid2;

        if ($server_tag && exists $THREAD_PD_MAP{$server_tag}) {
            my @matches = grep {
                index($_, $short) == 0 || index($short, $_) == 0
            } keys %{$THREAD_PD_MAP{$server_tag}};
            my %unique_pds = map { $THREAD_PD_MAP{$server_tag}{$_} => 1 } @matches;
            return 0 if keys %unique_pds > 1;
        }
        return 1;
    }
    return 0;
}

sub find_thread_pd_id {
    my ($server_tag, $target_tid) = @_;
    return undef unless $server_tag && defined($target_tid) && length($target_tid);
    return undef unless exists $THREAD_PD_MAP{$server_tag};

    # Exact match on stored key (full/canonical or existing)
    if (exists $THREAD_PD_MAP{$server_tag}{$target_tid}) {
        return $THREAD_PD_MAP{$server_tag}{$target_tid};
    }

    # If target_tid is already canonical, do not prefix-match other threads
    return undef if is_canonical_tid($target_tid);

    # Unresolved short ID fallback: prefix match against stored full keys
    my @matches = grep {
        index($_, $target_tid) == 0
    } keys %{$THREAD_PD_MAP{$server_tag}};

    my %unique_pds = map { $THREAD_PD_MAP{$server_tag}{$_} => 1 } @matches;
    my @pds = keys %unique_pds;

    return (@pds == 1) ? $pds[0] : undef;
}

sub set_thread_pd_map {
    my ($server_tag, $tid, $pd_id) = @_;
    return unless $server_tag && $tid && $pd_id;
    my $prev_pd_id = $THREAD_PD_MAP{$server_tag}{$tid};

    # If tid is canonical, upgrade any unexpanded shorter prefix stored for this incident
    if (is_canonical_tid($tid) && exists $THREAD_PD_MAP{$server_tag}) {
        for my $k (keys %{$THREAD_PD_MAP{$server_tag}}) {
            if ($k ne $tid && index($tid, $k) == 0 && $THREAD_PD_MAP{$server_tag}{$k} eq $pd_id) {
                delete $THREAD_PD_MAP{$server_tag}{$k};
                @{$THREAD_PD_ORDER{$server_tag}} = grep { $_ ne $k } @{$THREAD_PD_ORDER{$server_tag}};
            }
        }
    }

    $THREAD_PD_MAP{$server_tag}{$tid} = $pd_id;
    # Maintain LRU ordering
    @{$THREAD_PD_ORDER{$server_tag}} = grep { $_ ne $tid } @{$THREAD_PD_ORDER{$server_tag} // []};
    push(@{$THREAD_PD_ORDER{$server_tag}}, $tid);
    if (@{$THREAD_PD_ORDER{$server_tag}} > 50) {
        my $old_tid = shift(@{$THREAD_PD_ORDER{$server_tag}});
        my $old_pd_id = delete $THREAD_PD_MAP{$server_tag}{$old_tid};
        if ($old_pd_id && !(grep { $_ eq $old_pd_id } @PD_CACHE) && !is_pd_id_mapped($old_pd_id)) {
            delete $PD_STATUS{$old_pd_id};
        }
    }
    if ($prev_pd_id && $prev_pd_id ne $pd_id && !(grep { $_ eq $prev_pd_id } @PD_CACHE) && !is_pd_id_mapped($prev_pd_id)) {
        delete $PD_STATUS{$prev_pd_id};
    }
}

sub cmd_pagerduty_cache_dump {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);
    my $server_tag = $server ? $server->{tag} : '';

    if ($server_tag && exists $THREAD_PD_MAP{$server_tag} && scalar(keys %{$THREAD_PD_MAP{$server_tag}}) > 0) {
        _wi_print($wi, 'Mapped Threads:');
        foreach my $t (sort keys %{$THREAD_PD_MAP{$server_tag}}) {
            my $col = thread_color($t);
            my $short_t = short_thread_id($t);
            my $pd_id = $THREAD_PD_MAP{$server_tag}{$t};
            my $status_str = (exists $PD_STATUS{$pd_id} && length $PD_STATUS{$pd_id}) ? " ($PD_STATUS{$pd_id})" : "";
            _wi_print($wi, "${col}[${short_t}]\x0f -> $pd_id$status_str");
        }
    } elsif (scalar(keys %{$THREAD_PD_MAP{$server_tag}}) == 0) {
        _wi_print($wi, 'Empty PagerDuty incidents in cache, see ' . $pd_url);
    }
};
Irssi::command_bind('pagerduty_cache_dump', 'cmd_pagerduty_cache_dump');

sub cmd_pagerduty_cache_dump_active {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);
    my $server_tag = $server ? $server->{tag} : '';

    if (scalar(@PD_CACHE) == 0) {
        _wi_print($wi, 'Empty active PagerDuty incidents in cache, see ' . $pd_url);
    } else {
        foreach my $pd_id (@PD_CACHE) {
            my $status_str = (exists $PD_STATUS{$pd_id} && length $PD_STATUS{$pd_id}) ? " ($PD_STATUS{$pd_id})" : "";
            _wi_print($wi, $pd_id . $status_str . ' - ' . $pd_url . $pd_id);
        }
    }
};
Irssi::command_bind('pagerduty_cache_dump_active', 'cmd_pagerduty_cache_dump_active');

my $PD_CACHE_INDEX = 0;

sub signal_message_public {
    my ($server, $msg, $nick, $address, $target) = @_;

    return unless chatnet_enabled($server);

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless lc($target) eq lc($pagerduty_channel);

    my $server_tag = $server->{tag};
    my $bot_nick = Irssi::settings_get_str('is_pd_bot_nick');

    if ((lc($target) eq lc($pagerduty_channel)) && (lc($nick) eq lc($bot_nick))) {
        my $pd_id;

        # Ordering matters, TRIGGERED can also be part of the
        # parent/thread msg. Ignore thread reply quotes so
        # quoted parent incidents don't re-enter the cache.
        my $clean_msg = $msg;
        $clean_msg =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
        $clean_msg =~ s/[\x02\x0f\x16\x1d\x1f]//g;
        $clean_msg =~ s/(?:\xc2\xa0|\x{a0})/ /g;
        $clean_msg =~ s/\(re (?>[^()]|(?<paren>\((?>[^()]|(?&paren))*\)))*?\@${bot_nick}: (?>[^()]|(?&paren))*\)//g;
        $clean_msg =~ s/\(re [^)]*?\@${bot_nick}: .*?\)//g;

        # Extract thread ID from message brackets if present
        my $tid;
        if ($clean_msg =~ /\[(?:->|↪)?\@\@([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})/) {
            $tid = $1;
        } elsif ($clean_msg =~ /\[(?:->|↪)([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})(?:…|\.\.\.|\]|,)/) {
            $tid = $1;
        } elsif ($clean_msg =~ /\[([0-9a-f]{3}|[0-9a-z]{26}|\$[0-9A-Za-z\-_\.]{1,43}|[0-9a-z]{1,25}(?:…|\.\.\.))\]/) {
            $tid = $1;
            $tid =~ s/(?:…|\.\.\.)$//;
        }
        $tid = resolve_thread_id($target, $tid) if $tid;

        # Clear pending continuation if explicit thread context changes; carry pending thread on untagged continuations
        if ($PENDING_TID{$server_tag} && defined($tid)) {
            if (is_thread_alias($server_tag, $tid, $PENDING_TID{$server_tag})) {
                if (length($tid) > length($PENDING_TID{$server_tag})) {
                    $PENDING_TID{$server_tag} = $tid;
                } else {
                    $tid = $PENDING_TID{$server_tag};
                }
            } else {
                $PENDING_PD_ID{$server_tag} = undef;
            }
        }
        if ($tid) {
            $PENDING_TID{$server_tag} = $tid;
        } else {
            $tid = $PENDING_TID{$server_tag};
        }

        # Track pending incident ID from URL, table row, or wrapped bare ID
        if ($clean_msg =~ /(?:incidents\/|[🮇\|]\s*|\b)(P[A-Z0-9]{6}|Q[A-Z0-9]{13})\b/ && $clean_msg !~ /Alert ID/) {
            $PENDING_PD_ID{$server_tag} = $1;
            set_thread_pd_map($server_tag, $tid, $PENDING_PD_ID{$server_tag});
        }

        # Clean up resolved PagerDuty incident from cache (same-line or wrapped table)
        if (($clean_msg =~ /(P[A-Z0-9]{6}|Q[A-Z0-9]{13})\s+.*✅ RESOLVED/) || ($PENDING_PD_ID{$server_tag} && $clean_msg =~ /✅ RESOLVED/)) {
            my $resolved_id = $1 || $PENDING_PD_ID{$server_tag};
            set_thread_pd_map($server_tag, $tid, $resolved_id);
            if (is_pd_id_mapped($resolved_id)) {
                $PD_STATUS{$resolved_id} = '✅ RESOLVED';
            } else {
                delete $PD_STATUS{$resolved_id};
            }
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
            for my $i (0 .. $#PD_CACHE) {
                if ($PD_CACHE[$i] && ($PD_CACHE[$i] eq $resolved_id)) {
                    splice(@PD_CACHE, $i, 1);
                    last;
                }
            }
        }
        # Match active PagerDuty incidents to populate cache (same-line or wrapped table)
        elsif ($clean_msg =~ /(P[A-Z0-9]{6}|Q[A-Z0-9]{13})\s+.*(🚨 TRIGGERED|🆗 ACKNOWLEDGED|(?:‼|‼️|!!) UNACKNOWLEDGED|📤 ESCALATED|📥 (?:RE)?ASSIGNED|💤 SNOOZED)/) {
            $pd_id = $1;
            my $raw_status = $2;
            $PD_STATUS{$pd_id} = ($raw_status =~ /UNACKNOWLEDGED/) ? '‼️ UNACKNOWLEDGED' : $raw_status;
            set_thread_pd_map($server_tag, $tid, $pd_id);
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
        }
        elsif ($PENDING_PD_ID{$server_tag} && $clean_msg =~ /(🚨 TRIGGERED|🆗 ACKNOWLEDGED|(?:‼|‼️|!!) UNACKNOWLEDGED|📤 ESCALATED|📥 (?:RE)?ASSIGNED|💤 SNOOZED)/) {
            $pd_id = $PENDING_PD_ID{$server_tag};
            my $raw_status = $1;
            $PD_STATUS{$pd_id} = ($raw_status =~ /UNACKNOWLEDGED/) ? '‼️ UNACKNOWLEDGED' : $raw_status;
            set_thread_pd_map($server_tag, $tid, $pd_id);
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
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
                    last;
                }
            }
            # Store most recently seen PagerDuty incidents at the start.
            unshift(@PD_CACHE, $pd_id);
            # Remove last seen PagerDuty incidents if reached max. cache size.
            if (scalar(@PD_CACHE) > get_pagerduty_cache_size()) {
                my $popped = pop(@PD_CACHE);
                if ($popped && !is_pd_id_mapped($popped)) {
                    delete $PD_STATUS{$popped};
                }
            }
        }
    }
};
Irssi::signal_add_first('message public', 'signal_message_public');

# Tab auto-completion for PagerDuty incident IDs in cache
sub signal_complete_word_pagerduty {
    my ($complist, $window, $word, $linestart, $want_space) = @_;

    return unless chatnet_enabled($window->{active_server});
    return unless $window->{active};

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless (lc($window->{active}->{name}) eq lc($pagerduty_channel) || $window->{active}->{name} =~ /^@@/);

    return unless $word =~ /^[PQ]/i;

    my %seen;
    # Prioritize thread-mapped incident if replying in a thread context
    my $thread_id;
    if ($linestart && $linestart =~ /^@@([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})/i) {
        $thread_id = $1;
    } elsif ($window->{active}->{name} =~ /^@@([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})/i) {
        $thread_id = $1;
    }

    if ($thread_id) {
        my $channel = (lc($window->{active}->{name}) eq lc($pagerduty_channel)) ? $window->{active}->{name} : $pagerduty_channel;
        my $target_tid = resolve_thread_id($channel, $thread_id);
        my $server = $window->{active_server};
        my $server_tag = $server ? $server->{tag} : '';
        my $mapped_id = find_thread_pd_id($server_tag, $target_tid);
        if ($mapped_id && index(uc($mapped_id), uc($word)) == 0) {
            push(@$complist, $mapped_id);
            $seen{$mapped_id} = 1;
        }
    }

    foreach my $pd_id (@PD_CACHE) {
        next if $seen{$pd_id}++;
        push(@$complist, $pd_id) if index(uc($pd_id), uc($word)) == 0;
    }
}
Irssi::signal_add_last('complete word', 'signal_complete_word_pagerduty');

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_ADDED = 0;
my $PD_SEPARATOR_ADDED = 0;
sub cmd_pagerduty_cache_search {
    my ($data, $server, $wi) = @_;

    my $pagerduty_channel = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
    $pagerduty_channel = "#$pagerduty_channel" unless $pagerduty_channel =~ /^#/;
    return unless ref $wi and (lc($wi->{name}) eq lc($pagerduty_channel) || $wi->{name} =~ /^@@/);

    return unless chatnet_enabled($server);

    my $pd_id;
    my $input = Irssi::parse_special('$L');

    # Check if in thread context (prompt starts with @@<id> or inside an @@<id> window)
    my $thread_id;
    if ($input =~ /^@@([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})/i) {
        $thread_id = $1;
    } elsif ($wi->{name} =~ /^@@([0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})/i) {
        $thread_id = $1;
    }

    if ($thread_id) {
        my $channel = (lc($wi->{name}) eq lc($pagerduty_channel)) ? $wi->{name} : $pagerduty_channel;
        my $target_tid = resolve_thread_id($channel, $thread_id);
        my $server_tag = $server ? $server->{tag} : '';

        $pd_id = find_thread_pd_id($server_tag, $target_tid);
        return unless $pd_id;
    }

    # If not in thread context, cycle active cache
    if (!$pd_id && @PD_CACHE) {
        $pd_id = $PD_CACHE[$PD_CACHE_INDEX];
        $PD_CACHE_INDEX += 1;
        if ($PD_CACHE_INDEX > $#PD_CACHE) {
            # Cycle back to the start.
            $PD_CACHE_INDEX = 0;
        }
    }

    if ($pd_id) {
        $PD_CACHE_SEARCH_ENABLED = 1;

        if (!$PD_ADDED) {
            $PD_SEPARATOR_ADDED = 0;
        }

        # Replace previously inserted standalone PagerDuty incident, or append with spacing
        if (!($input =~ s/(P[A-Z0-9]{6}|Q[A-Z0-9]{13})$/${pd_id}/)) {
            $PD_SEPARATOR_ADDED = ($input =~ /\S$/) ? 1 : 0;
            $input .= ' ' if $PD_SEPARATOR_ADDED;
            $input .= $pd_id;
        }

        # Insert PagerDuty incident from cache.
        Irssi::gui_input_set_pos(0);
        Irssi::gui_input_set($input);

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
        $PD_SEPARATOR_ADDED = 0;
        $PD_CACHE_INDEX = 0;
        $PD_CACHE_SEARCH_ENABLED = 0;
    }

    # Cancel/abort.
    elsif ($key == $KEY_CTRL_C) {
        my $input = Irssi::parse_special('$L');

        # Remove the Ctrl+C character.
        $input =~ tr/\x03//d;

        if ($PD_ADDED) {
            my $pos = Irssi::gui_input_get_pos();
            if ($PD_SEPARATOR_ADDED) {
                if ($input =~ s/\s(P[A-Z0-9]{6}|Q[A-Z0-9]{13})$//) {
                    $pos -= length($1) + 1;
                }
            } else {
                if ($input =~ s/(P[A-Z0-9]{6}|Q[A-Z0-9]{13})$//) {
                    $pos -= length($1);
                }
            }

            # We also want to move the input position back one for
            # Ctrl+C char.
            $pos = $pos > 0 ? $pos - 1 : 0;

            # Replace the text in the input box with our modified
            # version, then move cursor positon to where it was
            # without the inserted PagerDuty incident.
            Irssi::gui_input_set($input);
            Irssi::gui_input_set_pos($pos);
        }

        $PD_ADDED = 0;
        $PD_SEPARATOR_ADDED = 0;
        $PD_CACHE_INDEX = 0;
        $PD_CACHE_SEARCH_ENABLED = 0;
    }
};
Irssi::signal_add_last('gui key pressed', 'signal_gui_key_pressed');
