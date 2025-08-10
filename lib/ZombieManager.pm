package ZombieManager;
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use File::Slurp;
use JSON;
use POSIX qw(strftime);
use Logger;

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
    my ($self) = @_;
    my $qb = $self->{qb};
    my %zombies;

    my $session = $qb->get_torrents_infohash();
    my @infohashes = keys %$session;
    my $count = scalar @infohashes;

    my @spinner = ('|', '/', '-', '\\');
    my $i = 0;

    foreach my $ih (@infohashes) {
        # Spinner output
        print "\r[SCAN] Checking $i/$count " . $spinner[$i % @spinner];
        $i++;

        my $files = $qb->get_torrent_files($ih);
        if (!@$files) {
            $zombies{$ih} = $session->{$ih};
        }
    }
    print "\r" . (' ' x 50) . "\r"; # Clear spinner line

    Logger::info("[SUMMARY] Zombie torrents in qBittorrent: " . scalar keys %zombies);
    return \%zombies;
}

sub write_cache {
    my ($self, $zombies) = @_;
    return unless $zombies && ref $zombies eq 'HASH';

    my $dir = "cache";
    make_path($dir) unless -d $dir;

    unlink glob("$dir/zombies_cache_*.json");

    my $ts = strftime("%y.%m.%d-%H%M", localtime);
    my $file = File::Spec->catfile($dir, "zombies_cache_${ts}.json");
    write_file($file, JSON->new->utf8->pretty->encode($zombies));

    Logger::info("[INFO] Zombie cache written to $file (" . scalar(keys %$zombies) . " entries)");
    return $file;
}

sub load_cache {
    my ($self) = @_;
    my ($latest) = sort { $b cmp $a } glob("cache/zombies_cache_*.json");
    return unless $latest && -f $latest;

    my $json;
    eval { $json = decode_json(read_file($latest)); };
    if ($@) {
        Logger::error("[ERROR] Failed to read zombie cache: $@");
        return;
    }
    Logger::info("[INFO] Loaded zombie cache from $latest (" . scalar(keys %$json) . " entries)");
    return $json;
}

sub classify_zombies {
    Logger::debug("#\tclassify_zombies");

    my ($zombies, $parsed_torrents) = @_;
    die "[ERROR] Missing zombies hashref" unless $zombies && ref $zombies eq 'HASH';
    die "[ERROR] Missing parsed_torrents hashref" unless $parsed_torrents && ref $parsed_torrents eq 'HASH';

    my (%heal_candidates, %disposal_candidates);

    foreach my $zih (keys %$zombies) {
        my $zombie = $zombies->{$zih};
        my $name   = $zombie->{name} // '';

        # 1. Exact infohash match
        if (exists $parsed_torrents->{$zih}) {
            $heal_candidates{$zih} = $parsed_torrents->{$zih};
        }
        # 2. Zombie name matches a local torrent's infohash key
        elsif ($name && exists $parsed_torrents->{$name}) {
            $heal_candidates{$zih} = $parsed_torrents->{$name};
        }
        # 3. No match at all → disposal candidate
        else {
            $disposal_candidates{$zih} = $zombie;
        }
    }

    Logger::info("[INFO] Heal candidates: " . scalar(keys %heal_candidates) .
                 " / Disposal candidates: " . scalar(keys %disposal_candidates));

    return (\%heal_candidates, \%disposal_candidates);
}

sub write_heal_candidates {
    my ($self) = @_;
    my $heal = $self->{heal_candidates};
    return unless %$heal;

    my $dir = "cache";
    make_path($dir) unless -d $dir;
    my $ts = strftime("%y.%m.%d-%H%M", localtime);
    my $file = File::Spec->catfile($dir, "heal_candidates_${ts}.json");
    write_file($file, JSON->new->utf8->pretty->encode($heal));

    Logger::info("[INFO] Heal candidates written to $file (" . scalar(keys %$heal) . " entries)");
    return $file;
}

sub write_disposal_candidates {
    my ($self) = @_;
    my $dispose = $self->{disposal_candidates};
    return unless %$dispose;

    my $dir = "cache";
    make_path($dir) unless -d $dir;
    my $ts = strftime("%y.%m.%d-%H%M", localtime);
    my $file = File::Spec->catfile($dir, "disposal_candidates_${ts}.json");
    write_file($file, JSON->new->utf8->pretty->encode($dispose));

    Logger::info("[INFO] Disposal candidates written to $file (" . scalar(keys %$dispose) . " entries)");
    return $file;
}

sub classify_zombies_by_infohash_name {
    my ($zombies, $parsed) = @_;
    Logger::debug("#\tclassify_zombies_by_infohash_name");

    unless ($zombies && ref $zombies eq 'HASH') {
        Logger::error("[ERROR] Missing zombies hashref");
        return { heal => {}, next_filter => {} };
    }
    unless ($parsed && ref $parsed eq 'HASH') {
        Logger::error("[ERROR] Missing parsed torrents hashref");
        return { heal => {}, next_filter => {} };
    }

    my (%heal, %next_filter);
    foreach my $ih (keys %$zombies) {
        my $name = $zombies->{$ih}->{name};
        if ($name && exists $parsed->{$name}) {
            $heal{$ih} = $zombies->{$ih};
        } else {
            $next_filter{$ih} = $zombies->{$ih};
        }
    }

    Logger::info("[INFO] Heal candidates: " . scalar(keys %heal));
    Logger::info("[INFO] Sent to next filter: " . scalar(keys %next_filter));

    return {
        heal        => \%heal,
        next_filter => \%next_filter
    };
}

1;
