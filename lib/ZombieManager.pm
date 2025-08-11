package ZombieManager;

use common::Sense;
use File::Path qw(make_path);
use File::Spec;
use File::Slurp;
use JSON;
use POSIX qw(strftime);

use lib 'lib';
use Utils;
use Logger;
use Exporter 'import';

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

    my $total_zombies = scalar keys %zombies;
    Logger::info("[SUMMARY] Zombie torrents in qBittorrent: $total_zombies");

    # Always write zombies cache — keep 2 latest copies
    my $cache_file = Utils::write_cache(\%zombies, 'zombies', 2);
    Logger::info("[INFO] Zombie cache written to $cache_file ($total_zombies entries)");

    $self->{zombies} = \%zombies;   # keep in object for later
    return \%zombies;
}

sub write_cache {
    my ($data, $type, $keep_count) = @_;
    return unless $data;
    $keep_count ||= 2; # default to keeping 2 latest

    my $dir = "cache";
    make_path($dir) unless -d $dir;

    # Build file pattern for this cache type
    my $prefix = "zombies_cache_" . ($type || 'default');

    # Clean up old cache files first
    my @files = sort { -M $a <=> -M $b } glob("$dir/${prefix}_*.json");
    if (@files > $keep_count) {
        my @to_delete = @files[0 .. $#files - $keep_count];
        unlink @to_delete;
        Logger::info("[CLEANUP] Removed " . scalar(@to_delete) . " old cache files for type '$type'");
    }

    # Write the new cache file
    my $ts = strftime("%y.%m.%d-%H%M", localtime);
    my $file = File::Spec->catfile($dir, "${prefix}_${ts}.json");
    write_file($file, JSON->new->utf8->pretty->encode($data));

    Logger::info("[INFO] Zombie cache written to $file (" . scalar(keys %$data) . " entries)");

    # Update latest symlink/marker file
    my $latest = File::Spec->catfile($dir, "${prefix}_latest.json");
    unlink $latest if -e $latest;
    symlink $file, $latest or warn "[WARN] Could not create symlink $latest: $!";

    return $file;
}

sub load_cache {
    my ($label) = @_;

    die "[ERROR] load_cache() missing label argument" unless defined $label;

    my $dir = "cache";
    my $latest = File::Spec->catfile($dir, "zombies_cache_${label}_latest.json");

    unless (-e $latest) {
        Logger::warn("[WARN] No cache found for label '$label' — need to run a scan");
        return;
    }

    my $json;
    eval {
        $json = decode_json(read_file($latest));
        1;
    } or do {
        Logger::error("[ERROR] Failed to read/parse cache '$latest': $@");
        return;
    };

    Logger::info("[INFO] Zombie cache [$label] loaded from $latest (" . scalar(keys %$json) . " entries)");
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

sub match_by_date {
    my ($self, $extracted_ref, $wiggle_minutes) = @_;
    $wiggle_minutes ||= 10;

    return { matches => [], no_added_on => [], no_save_path => [], matches_count => 0, no_added_on_count => 0,
no_save_path_count => 0 }
        unless $extracted_ref && ref $extracted_ref eq 'ARRAY';

    my $zombies_ref = [ values %{$self->{zombies}} ];
    my @matches;
    my @no_added_on;
    my @no_save_path;

    foreach my $zombie (@$zombies_ref) {

        unless ($zombie->{added_on}) {
            push @no_added_on, $zombie;
            next;
        }

        my $added_on_epoch = $zombie->{added_on};
        my $start_time     = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($added_on_epoch - ($wiggle_minutes * 60)));
        my $end_time       = POSIX::strftime("%Y-%m-%d %H:%M:%S", localtime($added_on_epoch + ($wiggle_minutes * 60)));

        my $search_string = qq{kMDItemFSName=*.torrent && kMDItemFSCreationDate>="$start_time" &&
kMDItemFSCreationDate<="$end_time"};
        Logger::trace("[TRACE] Spotlight query for zombie $zombie->{name}: $search_string");

        # Call the shared Utils method
        my $results_ref = Utils::run_mdfind(query => $search_string);
        my @results     = @$results_ref;
        Logger::trace("[TRACE] Spotlight results for $zombie->{name}: " . scalar(@results) . " hits");

        # Filter by save_path if present
        if ($zombie->{save_path} && @results) {
            my $before_count = scalar(@results);
            @results = grep { index($_, $zombie->{save_path}) != -1 } @results;
            Logger::trace("[TRACE] Filtered by save_path ($zombie->{save_path}): $before_count → " . scalar(@results));
        } else {
            Logger::debug("[DEBUG] No save_path for zombie $zombie->{name}");
            push @no_save_path, $zombie unless @results;
        }

        if (@results) {
            $zombie->{matched_path} = $results[0]; # store the first match
            $zombie->{flag_for_deeper_testing} = 1;
            push @matches, $zombie;
        }
    }

    return {
        matches             => \@matches,
        no_added_on         => \@no_added_on,
        no_save_path        => \@no_save_path,
        matches_count       => scalar(@matches),
        no_added_on_count   => scalar(@no_added_on),
        no_save_path_count  => scalar(@no_save_path),
    };
}


1;
