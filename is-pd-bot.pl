use strict;
use warnings;

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

my $pd_url;

Irssi::settings_add_str('matterircd_complete', 'matterircd_complete_networks', '');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_nick', 'is-pd-bot');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_pagerduty_channel', 'is-pagerduty');
Irssi::settings_add_str('is_pd_bot', 'is_pd_bot_pagerduty_url', 'https://canonical.pagerduty.com/incidents/');
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
my $PD_CHANNEL;
my $BOT_NICK;

sub get_pagerduty_url {
    if (!defined $pd_url) {
        $pd_url = Irssi::settings_get_str('is_pd_bot_pagerduty_url');
        $pd_url = 'https://canonical.pagerduty.com/incidents/' unless defined($pd_url) && length($pd_url);
        $pd_url =~ s{/+$}{};
        $pd_url .= '/';
    }
    return $pd_url;
}

sub get_pagerduty_channel {
    if (!defined $PD_CHANNEL) {
        $PD_CHANNEL = Irssi::settings_get_str('is_pd_bot_pagerduty_channel');
        $PD_CHANNEL = "#$PD_CHANNEL" unless $PD_CHANNEL =~ /^#/;
    }
    return $PD_CHANNEL;
}

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

Irssi::signal_add('setup changed', sub { $CHATNETS_RAW = $PD_CHANNEL = $BOT_NICK = $pd_url = undef; });
Irssi::signal_add('setup reread',  sub { $CHATNETS_RAW = $PD_CHANNEL = $BOT_NICK = $pd_url = undef; });

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
    my $resolver = defined &Irssi::Script::matterircd_complete::msgthreadid_find
        ? \&Irssi::Script::matterircd_complete::msgthreadid_find
        : defined &Irssi::Script::Matterircd_Tab_Auto_Complete::msgthreadid_find
            ? \&Irssi::Script::Matterircd_Tab_Auto_Complete::msgthreadid_find : undef;
    if ($resolver) {
        local $@;
        my $full = eval { $resolver->($target, $id) };
        Irssi::print("is-pd-bot: thread ID lookup failed: $@") if $@;
        return $full if defined $full && length $full;
    }
    return $id;
}

sub thread_color {
    my ($id) = @_;
    return "\x03" . '03' unless defined $id && length $id;
    my $colorer = defined &Irssi::Script::matterircd_complete::thread_color
        ? \&Irssi::Script::matterircd_complete::thread_color
        : defined &Irssi::Script::Matterircd_Tab_Auto_Complete::thread_color
            ? \&Irssi::Script::Matterircd_Tab_Auto_Complete::thread_color : undef;
    if ($colorer) {
        local $@;
        my $color = eval { $colorer->($id) };
        Irssi::print("is-pd-bot: thread color lookup failed: $@") if $@;
        return $color if defined $color && length $color;
    }
    # Fallback deterministic mIRC color if matterircd_complete is unavailable
    my @colors = qw(03 04 06 07 09 10 11 12 13);
    my $n = 0;
    $n = ($n * 31 + ord($_)) % scalar(@colors) for split //, lc($id);
    return "\x03" . $colors[$n];
}

sub get_short_thread_len {
    my $len = Irssi::settings_get_int('matterircd_complete_message_thread_id_min')
        || Irssi::settings_get_int('matterircd_complete_shorten_message_thread_id');
    return ($len && $len > 0) ? $len : 5;
}

sub short_thread_id {
    my ($id) = @_;
    return $id unless defined $id && length $id;
    my $len = get_short_thread_len();
    my $thread_m_style = ($id =~ /^[0-9a-f]{3}$/) ? 1 : 0;
    if (($len < 25) && ($thread_m_style != 1) && (length($id) > $len)) {
        return substr($id, 0, $len) . '…';
    }
    return $id;
}

my %PD_CACHE;
my %PENDING_PD_ID;
my %PENDING_TID;
my %PENDING_SINCE;
my %THREAD_PD_MAP;
my %THREAD_PD_ORDER;
my %PD_STATUS;

sub is_canonical_tid {
    my ($tid) = @_;
    return 0 unless defined $tid && length $tid;
    return ($tid =~ /^[0-9a-z]{26}$/ || $tid =~ /^\$[0-9A-Za-z\-_\.]{43}$/) ? 1 : 0;
}

sub is_pd_id_mapped {
    my ($server_tag, $id) = @_;
    return 0 unless defined $id && exists $THREAD_PD_MAP{$server_tag};
    for my $mapped_id (values %{$THREAD_PD_MAP{$server_tag}}) {
        return 1 if $mapped_id eq $id;
    }
    return 0;
}

sub pd_cache_matches_filter {
    my ($server_tag, $pd_id, $filter) = @_;
    return 1 unless defined($filter) && length($filter);
    my $status = $PD_STATUS{$server_tag}{$pd_id} // '';
    return index(lc($pd_id), lc($filter)) >= 0 || index(lc($status), lc($filter)) >= 0;
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

    # Ensure each incident ID maps to only one thread per server
    if (exists $THREAD_PD_MAP{$server_tag}) {
        for my $k (keys %{$THREAD_PD_MAP{$server_tag}}) {
            if ($k ne $tid && $THREAD_PD_MAP{$server_tag}{$k} eq $pd_id) {
                delete $THREAD_PD_MAP{$server_tag}{$k};
            }
        }
    }
    @{$THREAD_PD_ORDER{$server_tag}} = grep {
        exists $THREAD_PD_MAP{$server_tag}{$_}
    } @{$THREAD_PD_ORDER{$server_tag} // []};

    $THREAD_PD_MAP{$server_tag}{$tid} = $pd_id;
    # Maintain LRU ordering
    @{$THREAD_PD_ORDER{$server_tag}} = grep {
        $_ ne $tid && exists $THREAD_PD_MAP{$server_tag}{$_}
    } @{$THREAD_PD_ORDER{$server_tag} // []};
    push(@{$THREAD_PD_ORDER{$server_tag}}, $tid);
    if (@{$THREAD_PD_ORDER{$server_tag}} > 50) {
        my $old_tid = shift(@{$THREAD_PD_ORDER{$server_tag}});
        my $old_pd_id = delete $THREAD_PD_MAP{$server_tag}{$old_tid};
        if ($old_pd_id && !(grep { $_ eq $old_pd_id } @{$PD_CACHE{$server_tag} // []}) && !is_pd_id_mapped($server_tag, $old_pd_id)) {
            delete $PD_STATUS{$server_tag}{$old_pd_id};
        }
    }
    if ($prev_pd_id && $prev_pd_id ne $pd_id && !(grep { $_ eq $prev_pd_id } @{$PD_CACHE{$server_tag} // []}) && !is_pd_id_mapped($server_tag, $prev_pd_id)) {
        delete $PD_STATUS{$server_tag}{$prev_pd_id};
    }
}

sub cmd_pagerduty_cache_dump {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);
    my $server_tag = $server ? $server->{tag} : '';
    my @threads = grep { exists $THREAD_PD_MAP{$server_tag}{$_} } @{$THREAD_PD_ORDER{$server_tag} // []};
    my ($limit) = $data =~ /(?:^|\s)(\d+)(?:\s|$)/;
    my $filter = $data;
    $filter =~ s/(?:^|\s)\Q$limit\E(?=\s|$)// if defined $limit;
    $filter =~ s/^\s+|\s+$//g;
    @threads = grep {
        pd_cache_matches_filter($server_tag, $THREAD_PD_MAP{$server_tag}{$_}, $filter)
    } @threads;

    if ($server_tag && @threads) {
        if ($limit && $limit > 0 && @threads > $limit) {
            splice(@threads, 0, @threads - $limit);
        }

        _wi_print($wi, 'Mapped Threads:');
        foreach my $t (@threads) {
            my $col = thread_color($t);
            my $short_t = short_thread_id($t);
            my $pd_id = $THREAD_PD_MAP{$server_tag}{$t};
            my $status_str = (exists $PD_STATUS{$server_tag}{$pd_id} && length $PD_STATUS{$server_tag}{$pd_id}) ? " ($PD_STATUS{$server_tag}{$pd_id})" : "";
            _wi_print($wi, "${col}[${short_t}]\x0f ➜ $pd_id$status_str");
        }
    } else {
        _wi_print($wi, 'No mapped PagerDuty incidents matching filter, see ' . get_pagerduty_url());
    }
};
Irssi::command_bind('pagerduty_cache_dump', 'cmd_pagerduty_cache_dump');

sub cmd_pagerduty_cache_dump_active {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);
    my $server_tag = $server ? $server->{tag} : '';

    my $cache = $PD_CACHE{$server_tag} // [];
    if (scalar(@$cache) == 0) {
        _wi_print($wi, 'Empty active PagerDuty incidents in cache, see ' . get_pagerduty_url());
    } else {
        my @items = @$cache;
        my ($limit) = $data =~ /(?:^|\s)(\d+)(?:\s|$)/;
        my $filter = $data;
        $filter =~ s/(?:^|\s)\Q$limit\E(?=\s|$)// if defined $limit;
        $filter =~ s/^\s+|\s+$//g;
        @items = grep { pd_cache_matches_filter($server_tag, $_, $filter) } @items;
        if ($limit && $limit > 0 && @items > $limit) {
            splice(@items, $limit);
        }
        @items = reverse @items;

        if (!@items) {
            _wi_print($wi, 'No active PagerDuty incidents matching filter.');
            return;
        }

        my $short_len = get_short_thread_len();
        my $unmapped_prefix = '—' . (' ' x ($short_len + 5));

        _wi_print($wi, 'Active PagerDuty incidents:');
        foreach my $pd_id (@items) {
            my $status_str = ' ' x 20;
            if (exists $PD_STATUS{$server_tag}{$pd_id} && length $PD_STATUS{$server_tag}{$pd_id}) {
                my $st = $PD_STATUS{$server_tag}{$pd_id};
                my ($word) = $st =~ /([A-Z]+)$/;
                my $pad = ' ' x (14 - length($word // ''));
                $status_str = " ($st)$pad";
            }
            my $thread_prefix = $unmapped_prefix;
            if ($server_tag && exists $THREAD_PD_MAP{$server_tag}) {
                my ($t) = grep { $THREAD_PD_MAP{$server_tag}{$_} eq $pd_id } reverse @{$THREAD_PD_ORDER{$server_tag} // []};
                if ($t) {
                    my $col = thread_color($t);
                    my $short_t = short_thread_id($t);
                    my $pad = ($short_len + 1) - length($short_t);
                    my $pad_str = ' ' x ($pad > 0 ? $pad : 0);
                    $thread_prefix = "${col}[${short_t}]\x0f$pad_str ➜ ";
                }
            }
            _wi_print($wi, "${thread_prefix}$pd_id$status_str ➜ " . get_pagerduty_url() . $pd_id);
        }
    }
};
Irssi::command_bind('pagerduty_cache_dump_active', 'cmd_pagerduty_cache_dump_active');

my %PD_CACHE_INDEX;

sub cmd_pagerduty_cache_clear {
    my ($data, $server, $wi) = @_;

    return unless chatnet_enabled($server);
    my $server_tag = $server ? $server->{tag} : '';
    my $filter = $data // '';
    $filter =~ s/^\s+|\s+$//g;
    my $clear_all = !length($filter) || lc($filter) eq 'all';
    my %pd_ids = map { $_ => 1 } (
        @{$PD_CACHE{$server_tag} // []},
        values %{$THREAD_PD_MAP{$server_tag} // {}},
        keys %{$PD_STATUS{$server_tag} // {}},
        (defined($PENDING_PD_ID{$server_tag}) ? $PENDING_PD_ID{$server_tag} : ())
    );
    my @removed = grep {
        $clear_all || index(lc($_), lc($filter)) >= 0
            || index(lc($PD_STATUS{$server_tag}{$_} // ''), lc($filter)) >= 0
    } keys %pd_ids;

    my $pending_tid_pd_id = defined($PENDING_TID{$server_tag})
        ? find_thread_pd_id($server_tag, $PENDING_TID{$server_tag}) : undef;
    if ($clear_all
        || (defined($PENDING_PD_ID{$server_tag})
            && grep { $_ eq $PENDING_PD_ID{$server_tag} } @removed)
        || (defined($pending_tid_pd_id)
            && grep { $_ eq $pending_tid_pd_id } @removed)) {
        delete $PENDING_PD_ID{$server_tag};
        delete $PENDING_TID{$server_tag};
        delete $PENDING_SINCE{$server_tag};
    }

    for my $pd_id (@removed) {
        @{$PD_CACHE{$server_tag}} = grep { $_ ne $pd_id } @{$PD_CACHE{$server_tag} // []};
        for my $tid (keys %{$THREAD_PD_MAP{$server_tag} // {}}) {
            delete $THREAD_PD_MAP{$server_tag}{$tid} if $THREAD_PD_MAP{$server_tag}{$tid} eq $pd_id;
        }
        delete $PD_STATUS{$server_tag}{$pd_id};
    }
    @{$THREAD_PD_ORDER{$server_tag}} = grep {
        exists $THREAD_PD_MAP{$server_tag}{$_}
    } @{$THREAD_PD_ORDER{$server_tag} // []};
    $PD_CACHE_INDEX{$server_tag} = 0;

    _wi_print($wi, @removed ? 'Cleared ' . scalar(@removed) . ' PagerDuty incident(s).' : 'No cached PagerDuty incidents matched.');
};
Irssi::command_bind('pagerduty_cache_clear', 'cmd_pagerduty_cache_clear');

sub signal_message_public {
    my ($server, $msg, $nick, $address, $target) = @_;

    return unless $server && defined($msg) && defined($nick) && defined($target) && chatnet_enabled($server);
    my $bot_nick = ($BOT_NICK //= Irssi::settings_get_str('is_pd_bot_nick'));
    return unless lc($nick) eq lc($bot_nick);

    my $pagerduty_channel = get_pagerduty_channel();
    my $server_tag = $server->{tag};

    if (lc($target) eq lc($pagerduty_channel)) {
        my $pd_id;
        my $cache = ($PD_CACHE{$server_tag} //= []);

        # Ordering matters, TRIGGERED can also be part of the
        # parent/thread msg. Ignore thread reply quotes so
        # quoted parent incidents don't re-enter the cache.
        my $clean_msg = $msg;
        $clean_msg =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
        $clean_msg =~ s/[\x02\x0f\x16\x1d\x1f]//g;
        $clean_msg =~ s/(?:\xc2\xa0|\x{a0})/ /g;
        $clean_msg =~ s/\(re (?>[^()]|(?<paren>\((?>[^()]|(?&paren))*\)))*?\@\Q${bot_nick}\E: (?>[^()]|(?&paren))*\)//g;
        $clean_msg =~ s/\(re [^)]*?\@\Q${bot_nick}\E: .*?\)//g;

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
        # Explicit prefixes can outlive pending continuations; only expand a unique full ID.
        if ($tid && !is_canonical_tid($tid) && exists $THREAD_PD_MAP{$server_tag}
            && !exists $THREAD_PD_MAP{$server_tag}{$tid}) {
            my @matches = grep {
                is_canonical_tid($_) && index($_, $tid) == 0
            } keys %{$THREAD_PD_MAP{$server_tag}};
            $tid = $matches[0] if @matches == 1;
        }
        my $explicit_tid = $tid;
        my $message_content = $clean_msg;
        if ($explicit_tid) {
            $message_content =~ s/^(?:\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?\]\s*)?\[(?:->|↪)?(?:\@\@)?(?:[0-9a-z]{1,26}|\$[0-9A-Za-z\-_\.]{1,43})(?:…|\.\.\.)?(?:,[^\]]+)?\]\s*//;
        }

        # Wrapped lines must arrive promptly; unrelated posts must not inherit stale context.
        if (exists $PENDING_SINCE{$server_tag} && time - $PENDING_SINCE{$server_tag} > 5) {
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag} = undef;
            delete $PENDING_SINCE{$server_tag};
        }
        if ($tid && !$PENDING_TID{$server_tag}) {
            $PENDING_PD_ID{$server_tag} = undef;
            delete $PENDING_SINCE{$server_tag};
        }

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
                delete $PENDING_SINCE{$server_tag};
            }
        }
        if ($tid) {
            $PENDING_TID{$server_tag} = $tid;
        } else {
            $tid = $PENDING_TID{$server_tag};
        }

        my $status_pattern = qr/(?:🚨 TRIGGERED|🆗 ACKNOWLEDGED|(?:‼|‼️|!!) UNACKNOWLEDGED|📤 ESCALATED|📥 (?:RE)?ASSIGNED|💤 SNOOZED|✅ RESOLVED)/;
        my ($url_pd_id) = $clean_msg =~ m{incidents/((?:P[A-Z0-9]{6}|Q[A-Z0-9]{13}))\b};
        my ($table_pd_id) = $message_content =~ /\A(?:🮇|\|)\s*((?:P[A-Z0-9]{6}|Q[A-Z0-9]{13}))\b/;
        my ($status_pd_id, $raw_status) = $message_content =~ /((?:P[A-Z0-9]{6}|Q[A-Z0-9]{13}))\s+.*?($status_pattern)/;
        my ($message_status) = $message_content =~ /($status_pattern)/;
        my $recognized_pd_id = $status_pd_id || $table_pd_id || $url_pd_id;
        my $has_pd_id = defined $recognized_pd_id;
        my $has_status = defined $message_status;
        my $has_table_marker = $message_content =~ /\A(?:🮇|\|)/;
        my $same_thread = $explicit_tid && $PENDING_TID{$server_tag}
            && is_thread_alias($server_tag, $explicit_tid, $PENDING_TID{$server_tag});
        if ($PENDING_PD_ID{$server_tag} && !$has_pd_id
            && (!$has_table_marker || !$has_status) && !$same_thread) {
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag} = undef;
            delete $PENDING_SINCE{$server_tag};
        }

        # Track pending incident ID from a URL, table row, or status-bearing line
        if ($recognized_pd_id && $clean_msg !~ /Alert ID/) {
            if ($PENDING_PD_ID{$server_tag} && $PENDING_PD_ID{$server_tag} ne $recognized_pd_id) {
                $tid = $PENDING_TID{$server_tag} = undef unless $explicit_tid;
                delete $PENDING_SINCE{$server_tag};
            }
            $PENDING_PD_ID{$server_tag} = $recognized_pd_id;
            set_thread_pd_map($server_tag, $tid, $PENDING_PD_ID{$server_tag});
        }

        # Clean up resolved PagerDuty incident from cache (same-line or wrapped table)
        if (($status_pd_id && $raw_status =~ /✅ RESOLVED/) || ($PENDING_PD_ID{$server_tag} && $clean_msg =~ /✅ RESOLVED/)) {
            my $resolved_id = $status_pd_id || $PENDING_PD_ID{$server_tag};
            set_thread_pd_map($server_tag, $tid, $resolved_id);
            if (is_pd_id_mapped($server_tag, $resolved_id)) {
                $PD_STATUS{$server_tag}{$resolved_id} = '✅ RESOLVED';
            } else {
                delete $PD_STATUS{$server_tag}{$resolved_id};
            }
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
            for my $i (0 .. $#$cache) {
                if ($cache->[$i] && ($cache->[$i] eq $resolved_id)) {
                    splice(@$cache, $i, 1);
                    $PD_CACHE_INDEX{$server_tag} = 0;
                    last;
                }
            }
        }
        # Match active PagerDuty incidents to populate cache (same-line or wrapped table)
        elsif ($status_pd_id && $raw_status !~ /✅ RESOLVED/) {
            $pd_id = $status_pd_id;
            $PD_STATUS{$server_tag}{$pd_id} = ($raw_status =~ /UNACKNOWLEDGED/) ? '‼️ UNACKNOWLEDGED' : $raw_status;
            set_thread_pd_map($server_tag, $tid, $pd_id);
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
        }
        elsif ($PENDING_PD_ID{$server_tag} && $message_status && $message_status !~ /✅ RESOLVED/) {
            $pd_id = $PENDING_PD_ID{$server_tag};
            $raw_status = $message_status;
            $PD_STATUS{$server_tag}{$pd_id} = ($raw_status =~ /UNACKNOWLEDGED/) ? '‼️ UNACKNOWLEDGED' : $raw_status;
            set_thread_pd_map($server_tag, $tid, $pd_id);
            $PENDING_PD_ID{$server_tag} = undef;
            $PENDING_TID{$server_tag}   = undef;
        }

        if ($PENDING_PD_ID{$server_tag} || $PENDING_TID{$server_tag}) {
            $PENDING_SINCE{$server_tag} //= time;
        } else {
            delete $PENDING_SINCE{$server_tag};
        }

        if ($pd_id) {
            # Reset search index on changes.
            if ($cache->[0] && ($cache->[0] ne $pd_id)) {
                $PD_CACHE_INDEX{$server_tag} = 0;
            }

            # Make sure it doesn't already exist in the cache.
            for my $i (0 .. $#$cache) {
                if ($cache->[$i] && ($cache->[$i] eq $pd_id)) {
                    splice(@$cache, $i, 1);
                    last;
                }
            }
            # Store most recently seen PagerDuty incidents at the start.
            unshift(@$cache, $pd_id);
            # Remove last seen PagerDuty incidents if reached max. cache size.
            if (scalar(@$cache) > get_pagerduty_cache_size()) {
                my $popped = pop(@$cache);
                if ($popped && !is_pd_id_mapped($server_tag, $popped)) {
                    delete $PD_STATUS{$server_tag}{$popped};
                }
            }
        }
    }
};
Irssi::signal_add_first('message public', 'signal_message_public');

# Tab auto-completion for PagerDuty incident IDs in cache
sub signal_complete_word_pagerduty {
    my ($complist, $window, $word, $linestart, $want_space) = @_;

    return unless $window && chatnet_enabled($window->{active_server});
    return unless $window->{active};
    my $server_tag = $window->{active_server}->{tag};

    my $pagerduty_channel = get_pagerduty_channel();
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
        my $mapped_id = find_thread_pd_id($server_tag, $target_tid);
        if ($mapped_id && index(uc($mapped_id), uc($word)) == 0) {
            push(@$complist, $mapped_id);
            $seen{$mapped_id} = 1;
        }
    }

    foreach my $pd_id (@{$PD_CACHE{$server_tag} // []}) {
        next if $seen{$pd_id}++;
        push(@$complist, $pd_id) if index(uc($pd_id), uc($word)) == 0;
    }
}
Irssi::signal_add_last('complete word', 'signal_complete_word_pagerduty');

my $PD_CACHE_SEARCH_ENABLED = 0;
my $PD_ADDED = 0;
my $PD_SEPARATOR_ADDED = 0;
my %PD_SEARCH_CONTEXT;

sub reset_pagerduty_search {
    $PD_CACHE_INDEX{$PD_SEARCH_CONTEXT{server}} = 0 if exists $PD_SEARCH_CONTEXT{server};
    $PD_CACHE_SEARCH_ENABLED = 0;
    $PD_ADDED = 0;
    $PD_SEPARATOR_ADDED = 0;
    %PD_SEARCH_CONTEXT = ();
}

sub pagerduty_search_context_matches {
    my ($window, $server, $input, $ctrl_c_pos) = @_;
    return 0 unless $PD_CACHE_SEARCH_ENABLED && $window && $server && $window->{active};
    return 0 unless $window->{refnum} == $PD_SEARCH_CONTEXT{window}
        && $server->{tag} eq $PD_SEARCH_CONTEXT{server}
        && $window->{active}->{name} eq $PD_SEARCH_CONTEXT{target};
    return 1 if $input eq $PD_SEARCH_CONTEXT{input};
    return defined($ctrl_c_pos) && $ctrl_c_pos > 0 && $ctrl_c_pos <= length($input)
        && substr($input, $ctrl_c_pos - 1, 1) eq "\x03"
        && (substr($input, 0, $ctrl_c_pos - 1) . substr($input, $ctrl_c_pos)) eq $PD_SEARCH_CONTEXT{input};
}

Irssi::signal_add('window changed', 'reset_pagerduty_search');
sub signal_pagerduty_window_context_changed {
    my ($window) = @_;
    return unless $window && exists $PD_SEARCH_CONTEXT{window};
    reset_pagerduty_search() if $window->{refnum} == $PD_SEARCH_CONTEXT{window};
}
Irssi::signal_add('window item changed', 'signal_pagerduty_window_context_changed');
Irssi::signal_add('window server changed', 'signal_pagerduty_window_context_changed');

sub cmd_pagerduty_cache_search {
    my ($data, $server, $wi) = @_;

    my $pagerduty_channel = get_pagerduty_channel();
    return unless ref $wi and (lc($wi->{name}) eq lc($pagerduty_channel) || $wi->{name} =~ /^@@/);

    return unless chatnet_enabled($server);

    my $server_tag = $server->{tag};
    my $window = Irssi::active_win();
    return unless $window && $window->{active}
        && $window->{active}->{name} eq $wi->{name}
        && $window->{active_server}
        && $window->{active_server}->{tag} eq $server_tag;

    my $pd_id;
    my $input = Irssi::parse_special('$L');
    reset_pagerduty_search() unless pagerduty_search_context_matches($window, $server, $input);

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
        $pd_id = find_thread_pd_id($server_tag, $target_tid);
        return unless $pd_id;
    }

    # If not in thread context, cycle active cache
    my $cache = $PD_CACHE{$server_tag} // [];
    if (!$pd_id && @$cache) {
        $PD_CACHE_INDEX{$server_tag} //= 0;
        $PD_CACHE_INDEX{$server_tag} = 0 if $PD_CACHE_INDEX{$server_tag} > $#$cache;
        $pd_id = $cache->[$PD_CACHE_INDEX{$server_tag}];
        $PD_CACHE_INDEX{$server_tag} += 1;
        if ($PD_CACHE_INDEX{$server_tag} > $#$cache) {
            # Cycle back to the start.
            $PD_CACHE_INDEX{$server_tag} = 0;
        }
    }

    if ($pd_id) {
        $PD_CACHE_SEARCH_ENABLED = 1;

        if (!$PD_ADDED) {
            $PD_SEPARATOR_ADDED = 0;
        }

        # Replace previously inserted standalone PagerDuty incident, or append with spacing
        if (!$PD_ADDED || !($input =~ s/(?<!\S)(P[A-Z0-9]{6}|Q[A-Z0-9]{13})\z/${pd_id}/)) {
            $PD_SEPARATOR_ADDED = ($input =~ /\S$/) ? 1 : 0;
            $input .= ' ' if $PD_SEPARATOR_ADDED;
            $input .= $pd_id;
        }

        # Insert PagerDuty incident from cache.
        Irssi::gui_input_set_pos(0);
        Irssi::gui_input_set($input);

        $PD_ADDED = 1;
        %PD_SEARCH_CONTEXT = (
            window => $window->{refnum},
            server => $server_tag,
            target => $wi->{name},
            input => $input,
        );
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
    my $input = Irssi::parse_special('$L');
    my $ctrl_c_pos = ($key == $KEY_CTRL_C) ? Irssi::gui_input_get_pos() : undef;
    # Irssi may already have inserted Ctrl+C before this last-priority handler.
    unless (chatnet_enabled($server)
        && pagerduty_search_context_matches(Irssi::active_win(), $server, $input, $ctrl_c_pos)) {
        reset_pagerduty_search();
        return;
    }
    my $ctrl_c_inserted = 0;
    if (defined($ctrl_c_pos) && $input ne $PD_SEARCH_CONTEXT{input}) {
        substr($input, $ctrl_c_pos - 1, 1, '');
        $ctrl_c_inserted = 1;
    }

    if (($key == $KEY_RET) || ($key == $KEY_CTRL_U)) {
        reset_pagerduty_search();
    }

    # Cancel/abort.
    elsif ($key == $KEY_CTRL_C) {
        if ($PD_ADDED) {
            my $pos = Irssi::gui_input_get_pos() - $ctrl_c_inserted;
            if ($PD_SEPARATOR_ADDED) {
                $input =~ s/\s(P[A-Z0-9]{6}|Q[A-Z0-9]{13})$//;
            } else {
                $input =~ s/(P[A-Z0-9]{6}|Q[A-Z0-9]{13})$//;
            }

            $pos = length($input) if $pos > length($input);
            $pos = 0 if $pos < 0;

            # Replace the text in the input box with our modified
            # version, then move cursor positon to where it was
            # without the inserted PagerDuty incident.
            Irssi::gui_input_set($input);
            Irssi::gui_input_set_pos($pos);
        }

        reset_pagerduty_search();
    }
};
Irssi::signal_add_last('gui key pressed', 'signal_gui_key_pressed');
