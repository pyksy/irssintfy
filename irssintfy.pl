# Script to send notifications from Irssi via ntfy; https://ntfy.sh/
# Hacked from IrssiNotifier script; https://github.com/murgo/IrssiNotifier

use strict;
use warnings;
no warnings 'closure';

use Irssi;
use IPC::Open2 qw(open2);
use Fcntl;
use POSIX;
use Encode;
use vars qw($VERSION %IRSSI);

$VERSION = "0.1";
%IRSSI   = (
    authors     => "pyksy",
    contact     => "irssintfy\@molukki.com",
    name        => "IrssiNtfy",
    description => "Send notifications from Irssi to ntfy",
    license     => "Apache License, version 2.0",
    url         => "https://github.com/pyksy/irssintfy",
    changed     => "2024-10-29"
);

# Sometimes, for some unknown reason, perl emits warnings like the following:
#   Can't locate package Irssi::Nick for @Irssi::Irc::Nick::ISA
# This package statement is here to suppress it.
{ package Irssi::Nick }

my $lastMsg;
my $lastServer;
my $lastNick;
my $lastTarget;
my $lastWindow;
my $lastKeyboardActivity = time;
my $forked;
my $lastDcc = 0;
my @delayQueue = ();
my $screen_socket_path;

if (defined($ENV{STY})) {
    my $screen_ls = `LC_ALL="C" screen -ls 2> /dev/null`;
    if ($screen_ls !~ /^No Sockets found/s) {
        $screen_ls =~ /^.+\d+ Sockets? in ([^\n]+)\.\n.+$/s;
        $screen_socket_path = $1;
    } else {
        $screen_ls =~ /^No Sockets found in ([^\n]+)\.\n.+$/s;
        $screen_socket_path = $1;
    }
}

sub private {
    my ( $server, $msg, $nick, $address ) = @_;
    $lastServer  = $server;
    $lastMsg     = $msg;
    $lastNick    = "*$nick*";
    $lastTarget  = "PRIVATE MSG";
    $lastWindow  = $nick;
    $lastDcc = 0;
}

sub joined {
    my ( $server, $target, $nick, $address ) = @_;
    $lastServer  = $server;
    $lastMsg     = "joined";
    $lastNick    = $nick;
    $lastTarget  = $target;
    $lastWindow  = $target;
    $lastDcc = 0;
}

sub public {
    my ( $server, $msg, $nick, $address, $target ) = @_;
    $lastServer  = $server;
    $lastMsg     = $msg;
    $lastNick    = "<$nick>";
    $lastTarget  = $target;
    $lastWindow  = $target;
    $lastDcc = 0;
}

sub dcc {
    my ( $dcc, $msg ) = @_;
    $lastServer  = $dcc->{server};
    $lastMsg     = $msg;
    $lastNick    = $dcc->{nick};
    $lastTarget  = "DCC CHAT";
    $lastWindow  = $dcc->{target};
    $lastDcc = 1;
}

sub print_text {
    my ($dest, $text, $stripped) = @_;

    if (!defined $lastMsg || index($text, $lastMsg) == -1)
    {
        # text doesn't contain the message, so printed text is about something else and notification doesn't need to be sent
        return;
    }

    if (should_send_notification($dest))
    {
        send_notification();
    }
}

sub should_send_notification {
    my $dest = @_ ? shift : $_;

    my $opt = MSGLEVEL_HILIGHT | MSGLEVEL_MSGS;
    if (!$lastDcc && (!($dest->{level} & $opt) || ($dest->{level} & MSGLEVEL_NOHILIGHT))) {
        return 0; # not a hilight and not a dcc message
    }

    if (!are_settings_valid()) {
        return 0; # invalid settings
    }

    if (Irssi::settings_get_bool("irssintfy_away_only") && !$lastServer->{usermode_away}) {
        return 0; # away only
    }

    if ($lastDcc && !Irssi::settings_get_bool("irssintfy_enable_dcc")) {
        return 0; # dcc is not enabled
    }

    if (Irssi::settings_get_bool('irssintfy_screen_detached_only') && attached()) {
        return 0; # screen/tmux attached
    }

    if (Irssi::settings_get_bool("irssintfy_ignore_active_window") && $dest->{window}->{refnum} == Irssi::active_win()->{refnum}) {
        return 0; # ignore active window
    }

    my $ignored_servers_string = Irssi::settings_get_str("irssintfy_ignored_servers");
    if ($ignored_servers_string) {
        my @ignored_servers = split(/ /, $ignored_servers_string);
        my $server;

        foreach $server (@ignored_servers) {
            if (lc($server) eq lc($lastServer->{tag})) {
                return 0; # ignored server
            }
        }
    }

    my $ignored_channels_string = Irssi::settings_get_str("irssintfy_ignored_channels");
    if ($ignored_channels_string) {
        my @ignored_channels = split(/ /, $ignored_channels_string);
        my $channel;

        foreach $channel (@ignored_channels) {
            if (lc($channel) eq lc($lastWindow)) {
                return 0; # ignored channel
            }
        }
    }

    # Ignore any highlights from given nicks
    my $ignored_nicks_string = Irssi::settings_get_str("irssintfy_ignored_nicks");
    if ($ignored_nicks_string ne '') {
        my @ignored_nicks = split(/ /, $ignored_nicks_string);
        if (grep { lc($_) eq lc($lastNick) } @ignored_nicks) {
            return 0; # Ignored nick
        }
    }

    # Ignore any highlights that match any specified patterns
    my $ignored_highlight_pattern_string = Irssi::settings_get_str("irssintfy_ignored_highlight_patterns");
    if ($ignored_highlight_pattern_string ne '') {
        my @ignored_patterns = split(/ /, $ignored_highlight_pattern_string);
        if (grep { $lastMsg =~ /$_/i } @ignored_patterns) {
            return 0; # Ignored pattern
        }
    }

    # If specified, require a pattern to be matched before highlighting public messages
    my $required_public_highlight_pattern_string = Irssi::settings_get_str("irssintfy_required_public_highlight_patterns");
    if ($required_public_highlight_pattern_string ne '' && ($dest->{level} & MSGLEVEL_PUBLIC)) {
        my @required_patterns = split(/ /, $required_public_highlight_pattern_string);
        if (!(grep { $lastMsg =~ /$_/i } @required_patterns)) {
            return 0; # Required pattern not matched
        }
    }

    my $timeout = Irssi::settings_get_int('irssintfy_require_idle_seconds');
    if ($timeout > 0 && (time - $lastKeyboardActivity) <= $timeout && attached()) {
        return 0; # not enough idle seconds
    }

    return 1;
}

sub attached {
  return (tmux_attached() || screen_attached());
}

sub tmux_attached {
  if (!defined($ENV{'TMUX_PANE'})){
    return 0;
  }
  chomp(my $session_attached = `tmux display-message -p -t$ENV{'TMUX_PANE'} '#{session_attached}' 2> /dev/null`);
  chomp(my $window_active    = `tmux display-message -p -t$ENV{'TMUX_PANE'} '#{window_active}' 2> /dev/null`);
  return $session_attached && $window_active;
}

sub screen_attached {
    if (!$screen_socket_path || !defined($ENV{STY})) {
        return 0;
    }
    my $socket = $screen_socket_path . "/" . $ENV{'STY'};
    if (-e $socket && ((stat($socket))[2] & 00100) != 0) {
        return 1;
    }
    return 0;
}

sub is_dangerous_string {
    my $s = @_ ? shift : $_;
    return $s =~ m/"/ || $s =~ m/`/ || $s =~ m/\\/;
}

sub send_notification {
    if ($forked) {
        if (scalar @delayQueue < 10) {
            push @delayQueue, {
                            'msg' => $lastMsg,
                            'nick' => $lastNick,
                            'target' => $lastTarget,
                            'added' => time,
                            };
        } else {
            Irssi::print("IrssiNtfy: previous send is still in progress and queue is full, skipping notification");
        }
        return 0;
    }
    send_to_api();
}

sub send_to_api {
    my $type = shift || "notification";

    my ($readHandle,$writeHandle);
    pipe $readHandle, $writeHandle;
    $forked = 1;
    my $pid = fork();

    unless (defined($pid)) {
        Irssi::print("IrssiNtfy: couldn't fork - abort");
        close $readHandle; close $writeHandle;
        $forked = 0;
        return 0;
    }

    if ($pid > 0) {
        close $writeHandle;
        Irssi::pidwait_add($pid);
        my $target = {fh => $$readHandle, tag => undef, type => $type};
        $target->{tag} = Irssi::input_add(fileno($readHandle), INPUT_READ, \&read_pipe, $target);
    } else {
        eval {
            my $api_url    = Irssi::settings_get_str('irssintfy_api_url');
            my $auth_token = Irssi::settings_get_str('irssintfy_auth_token');
            my $proxy      = Irssi::settings_get_str('irssintfy_https_proxy');

            my $curl_cmd = "curl -o /dev/null -s -H \"Tags: irssi\"";
            my $data;


            if($proxy) {
                $ENV{https_proxy} = $proxy;
            }

            if($auth_token) {
                $curl_cmd = "$curl_cmd -H \"Authorization: Bearer $auth_token\"";
            }

            if ($type eq 'notification') {
                $lastMsg = Irssi::strip_codes($lastMsg);

                encode_utf();

                $data = "-d \"$lastNick $lastMsg\" -H \"Title: $lastTarget\"";
            }

            my $result =  `$curl_cmd $data $api_url`;
            if (($? >> 8) != 0) {
                # Something went wrong, might be network error or authorization issue. Probably no need to alert user, though.
                print $writeHandle "0 FAIL\n";
            } else {
                print $writeHandle "1 OK\n";
            }
        }; # end eval

        if ($@) {
            print $writeHandle "-1 IrssiNtfy internal error: $@\n";
        }

        close $readHandle; close $writeHandle;
        POSIX::_exit(1);
    }
    return 1;
}

sub encode_utf {
    # encode messages to utf8 if terminal is not utf8 (irssi's recode should be on)
    my $encoding;
    eval {
        require I18N::Langinfo;
        $encoding = lc(I18N::Langinfo::langinfo(I18N::Langinfo::CODESET()));
    };
    if ($encoding && $encoding !~ /^utf-?8$/i) {
        $lastMsg    = Encode::encode_utf8($lastMsg);
        $lastNick   = Encode::encode_utf8($lastNick);
        $lastTarget = Encode::encode_utf8($lastTarget);
    }
}

sub read_pipe {
    my $target = shift;
    my $readHandle = $target->{fh};

    my $output = <$readHandle>;
    chomp($output);

    close($target->{fh});
    Irssi::input_remove($target->{tag});
    $forked = 0;

    $output =~ /^(-?\d+) (.*)$/;
    my $ret = $1;
    $output = $2;

    if ($ret < 0) {
        Irssi::print($IRSSI{name} . ": Error: send crashed: $output");
    } elsif (!$ret) {
        #Irssi::print($IRSSI{name} . ": Error: send failed: $output");
    }

    check_delayQueue();
}

sub are_settings_valid {
    Irssi::signal_remove( 'gui key pressed', 'event_key_pressed' );
    if (Irssi::settings_get_int('irssintfy_require_idle_seconds') > 0) {
        Irssi::signal_add( 'gui key pressed', 'event_key_pressed' );
    }

    if (!Irssi::settings_get_str('irssintfy_api_url')) {
        Irssi::print("IrssiNtfy: Set API URL to send notifications: /set irssintfy_api_url [url]");
        return 0;
    }

    `curl --version`;
    if ($? == 127) {
        Irssi::print("IrssiNtfy: curl not found.");
        return 0;
    }

    return 1;
}

sub check_delayQueue {
    if (scalar @delayQueue > 0) {
      my $item = shift @delayQueue;
      if (time - $item->{'added'} > 60) {
          check_delayQueue();
          return 0;
      } else {
          $lastMsg = $item->{'msg'};
          $lastNick = $item->{'nick'};
          $lastTarget = $item->{'target'};
          send_notification();
          return 0;
      }
    }
    return 1;
}

sub event_key_pressed {
    $lastKeyboardActivity = time;
}

Irssi::settings_add_str('irssintfy', 'irssintfy_api_url', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_auth_token', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_https_proxy', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_ignored_servers', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_ignored_channels', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_ignored_nicks', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_ignored_highlight_patterns', '');
Irssi::settings_add_str('irssintfy', 'irssintfy_required_public_highlight_patterns', '');
Irssi::settings_add_bool('irssintfy', 'irssintfy_ignore_active_window', 0);
Irssi::settings_add_bool('irssintfy', 'irssintfy_away_only', 0);
Irssi::settings_add_bool('irssintfy', 'irssintfy_screen_detached_only', 0);
Irssi::settings_add_int('irssintfy', 'irssintfy_require_idle_seconds', 0);
Irssi::settings_add_bool('irssintfy', 'irssintfy_enable_dcc', 1);

Irssi::signal_add('message irc action', 'public');
Irssi::signal_add('message public',     'public');
Irssi::signal_add('message private',    'private');
Irssi::signal_add('message join',       'joined');
Irssi::signal_add('message dcc',        'dcc');
Irssi::signal_add('message dcc action', 'dcc');
Irssi::signal_add('print text',         'print_text');
Irssi::signal_add('setup changed',      'are_settings_valid');
