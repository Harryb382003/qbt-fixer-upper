use common::sense;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use JSON;
use Time::Piece;
use File::Spec;

use lib 'lib';
use Logger;


package QBittorrent;

use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Cookies;
use JSON;


use lib 'lib/';
use Logger;
use Utils qw(start_timer stop_timer sprinkle);


sub new {
	Logger::debug("#	new");
    my ($class, $opts) = @_;
    my $self = {
        base_url => $opts->{base_url} || 'http://localhost:8080',
        username => $opts->{username} || 'admin',
        password => $opts->{password} || 'adminadmin',
        ua       => LWP::UserAgent->new(cookie_jar => HTTP::Cookies->new),
        %$opts,
    };
    bless $self, $class;
    $self->_login;
    return $self;
}


sub _login {
	Logger::debug("#	_login");
    my $self = shift;
    my $res = $self->{ua}->post(
        "$self->{base_url}/api/v2/auth/login",
        {
            username => $self->{username},
            password => $self->{password}
        }
    );

    die "Login failed: " . $res->status_line unless $res->is_success;
}


sub get_preferences {
	Logger::debug("#	get_preferences");
    my $self = shift;
    my $res = $self->{ua}->get("$self->{base_url}/api/v2/app/preferences");

    die "Failed to get preferences: " . $res->status_line unless $res->is_success;

    return decode_json($res->decoded_content);
}


sub get_torrents_infohash {
	Logger::debug("#	get_torrents");
    start_timer("qBittorrent connect");
    my $self = shift;
    my $res = $self->{ua}->get("$self->{base_url}/api/v2/torrents/info");

    die "Failed to get torrents: " . $res->status_line unless $res->is_success;

    my $torrents = decode_json($res->decoded_content);
    my %hash = map { $_->{hash} => $_ } @$torrents;
    Logger::summary("[SUMMARY] Torrents loaded in qBittorrent     \t" . scalar(keys %hash));
#    Logger::info("Successfully loaded into cache " . scalar(keys %hash));
    stop_timer("qBittorrent connect");
    return \%hash;
}


sub get_torrent_files {
    my ($self, $infohash) = @_;
    my $res = $self->{ua}->get("$self->{base_url}/api/v2/torrents/files?hash=$infohash");

    unless ($res->is_success) {
        Logger::warn("[WARN] Failed to fetch files for torrent $infohash: " . $res->status_line);
        return;
    }

    my $files;
    eval { $files = decode_json($res->decoded_content); 1 }
        or do {
            Logger::warn("[WARN] Failed to parse JSON for torrent $infohash: $@");
            return;
        };

    return $files;
}


sub get_q_zombies {
	Logger::debug("#	get_q_zombies");
    my ($self, $opts) = @_;

    my %zombies;
    my $cache_dir = "cache";
    my $cache_pattern = "$cache_dir/qbt_zombies_*.json";

    # --- DEV MODE: Use latest cache if present ---
    if ($opts->{dev_mode} && !$opts->{scan_zombies}) {
        my @cache_files = glob($cache_pattern);
        if (@cache_files) {
            my $latest_cache = (sort @cache_files)[-1];
            Logger::info("[CACHE] Loading zombie torrent list from: $latest_cache");
            my $json = read_file($latest_cache);
            my $cached = decode_json($json);
            Logger::summary("[SUMMARY][CACHE] Zombie torrents in qBittorrent:\t" . scalar keys %$cached);
            return $cached;
        }
        else {
            Logger::warn("[WARN] No zombie cache found. Run with --scan-zombies to create it.");
            return {};
        }
    }

    # --- PROD MODE: Skip unless scan requested ---
    if (!$opts->{scan_zombies}) {
        Logger::info("[INFO] Skipping zombie scan. Use --scan-zombies to enable.");
        return {};
    }

    # --- LIVE SCAN ---
    Logger::info("[INFO] Scanning qBittorrent for zombie torrents (missing content)...");
    my $session = $self->get_torrents(); # { infohash => {...} }

    foreach my $ih (keys %$session) {
        my $res = $self->{ua}->get("$self->{base_url}/api/v2/torrents/files?hash=$ih");
        next unless $res->is_success;

        my $files = decode_json($res->decoded_content);
        if (!@$files) { # empty list means zombie
            $zombies{$ih} = $session->{$ih};
        }
    }

    Logger::summary("[SUMMARY][LIVE] Zombie torrents in qBittorrent:\t" . scalar keys %zombies);

    # --- Update Cache ---
    eval {
        make_path($cache_dir) unless -d $cache_dir;
        my $ts = strftime("%y.%m.%d-%H%M", localtime);
        my $cache_file = "$cache_dir/qbt_zombies_$ts.json";
        write_file($cache_file, JSON->new->utf8->pretty->encode(\%zombies));
        Logger::info("[CACHE] Zombie list updated: $cache_file");
    };
    Logger::warn("[WARN] Failed to update zombie cache: $@") if $@;

    return \%zombies;
}




1;


