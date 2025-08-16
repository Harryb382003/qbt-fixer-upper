package ZombieManager;

use common::sense;
use Data::Dumper;
use File::Path qw(make_path);
use File::Spec;
use File::Slurp;
use JSON;
use POSIX qw(strftime);

use lib 'lib';
use Utils;
use Logger;
use Exporter 'import';
use TorrentParser qw(match_by_date); # now importing from TorrentParser

our @EXPORT_OK = qw(
    write_cache
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        qb                   => $args{qb},
        heal_candidates      => {},
        disposal_candidates  => {},
    };
    bless $self, $class;
    return $self;
}

sub init {
    my ($self, $opts) = @_;

    my ($zombies, $zombie_file) = Utils::load_cache('zombies');

    if ($opts->{scan}) {
        Logger::info("[ZOMBIE] Forcing zombie scan (wiggle:$opts->{wiggle}m)");
        $zombies = $self->scan_full($opts);
        if ($zombies && %$zombies) {
            Utils::write_cache($zombies, 'zombies');
        }
    }
    elsif ($opts->{dezombify}) {
        if ($zombies && %$zombies) {
            Logger::info("[ZOMBIE] zombies cache loaded from $zombie_file (" . scalar(keys %$zombies) . " entries)");
        }
        else {
            Logger::warn("[ZOMBIE] No zombie cache found for --dezombify, skipping.");
            $zombies = {};
        }
    }
    else {
        Logger::info("[ZOMBIE] ZombieManager init skipped — no scan or dezombify requested");
        $zombies = {};
    }

    $self->{zombies} = $zombies;
    say "[ZombieManager.pm line " . __LINE__ . "] \$self->{zombies} keys: " . scalar(keys %{$self->{zombies} || {}});

    return $self;
}

sub scan_full {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $wiggle = $opts->{wiggle} // 10;

    # Sanity check
    unless ($self->{qb} && $self->{qb}->can('get_torrents_infohash')) {
        Logger::error("[ZOMBIE] scan_full() called without a valid qBittorrent object");
        return {};
    }

    my $torrents = $self->{qb}->get_torrents_infohash();
    unless ($torrents && @$torrents) {
        Logger::warn("[ZOMBIE] No torrents returned from qBittorrent");
        return {};
    }

    say "[ZombieManager.pm line " . __LINE__ . "] \$torrents count: " . scalar(@$torrents);

    my %zombies;
    foreach my $t (@$torrents) {
        $zombies{ $t->{hash} } = {
            name        => $t->{name},
            added_on    => $t->{added_on},
            save_path   => $t->{save_path},
            source_path => $t->{source_path} || '',
        };
    }

    Logger::info("[ZOMBIE] Collected " . scalar(keys %zombies) . " possible zombies");
    return \%zombies;
}

1;
