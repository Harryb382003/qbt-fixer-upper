package ZombieManager;

use common::sense;
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



sub scan_full {
    my ($self, $opts) = @_;
    $opts ||= {};
    my $wiggle = $opts->{wiggle} // 10;

    # Sanity check qBittorrent object
    unless ($self->{qb} && $self->{qb}->can('torrents')) {
        Logger::error("[ZOMBIE] scan_full() called without a valid qBittorrent object");
        return {};
    }

    my $wiggle = $opts->{wiggle} // 10;
    Logger::debug("[ZOMBIE] Scanning qBittorrent cache for zombies (wiggle:${wiggle}m)");

    my $torrents = $self->{qb}->torrents();
    unless ($torrents && @$torrents) {
        Logger::warn("[ZOMBIE] No torrents returned from qBittorrent");
        return {};
    }

    my %zombies;
    foreach my $t (@$torrents) {
        # Minimal record — you can add more fields later
        $zombies{ $t->{hash} } = {
            name        => $t->{name},
            added_on    => $t->{added_on},
            save_path   => $t->{save_path},
            source_path => $t->{source_path} || '', # if available
        };
    }

    Logger::info("[ZOMBIE] Collected " . scalar(keys %zombies) . " possible zombies");
    return \%zombies;
}

# I don't know what the fuck
1;
