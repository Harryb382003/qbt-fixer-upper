
package TorrentParser;

use common::sense;
use Data::Dumper;

use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use Digest::SHA qw(sha1_hex);
use Bencode qw(bdecode bencode);
use File::Basename;
use JSON;
use List::Util qw(sum);
use Exporter 'import';

use lib 'lib/';
use Logger;
use Utils qw(start_timer stop_timer sprinkle);


our @EXPORT_OK = qw(
    extract_metadata
    match_by_date
    process_all_buckets
);

my $CACHE_FILE = "cache/hash_cache.json";
my $problem_log_file = "logs/problem_torrents.json";

my %hash_cache;

if (-e $CACHE_FILE) {
    my $json = read_file($CACHE_FILE);
    %hash_cache = %{ decode_json($json) };
}

# --- PUBLIC ---

sub new {
    my ($class, $args) = @_;
    my $self = {
        all_torrents => $args->{all_torrents},
        opts         => $args->{opts},
    };
    bless $self, $class;

    unless (ref $self->{all_torrents} eq 'ARRAY') {
        die "TorrentParser->new: expected all_torrents => ARRAYREF\n";
    }
    return $self;
}

sub extract_metadata {
    Logger::info("[MAIN] Starting TorrentParser metadata extraction");
    start_timer("extract_metadata");
    my ($self) = @_;
    my $opts          = $self->{opts};
    my $torrent_files = $self->{all_torrents};
    my %parsed_torrents;
    my %bucket_counts;
    my %seen;    # fast infohash lookup

    foreach my $file_path (@$torrent_files) {
        my $info = Utils::bdecode_file($file_path);
        unless ($info) {
            $parsed_torrents{problems}{$file_path} = { reason => 'bdecode failed' };
            next;
        }

        my $infohash = Utils::compute_infohash($info);
        unless ($infohash) {
            $parsed_torrents{problems}{$file_path} = { reason => 'no infohash' };
            next;
        }

        # --- Dedup check via seen hash ---
        if ($seen{$infohash}++) {
            push @{ $parsed_torrents{dupes}{$infohash} }, $file_path;
            next;
        }

        # --- Assign bucket ---
        my $bucket;
        if ($file_path =~ m{Completed_torrents}i) {
            $bucket = 'completed_torrents';
        }
        elsif ($file_path =~ m{BT_backup}i) {
            $bucket = 'bt_backup';
        }
        elsif ($file_path =~ m{Downloaded_torrents}i) {
            $bucket = 'downloaded_torrents';
        }
        else {
            $bucket = 'kitchen_sink';
        }
        $bucket_counts{$bucket}++;

        # --- Store primary torrent ---
        $parsed_torrents{$infohash} = {
            name        => $info->{name} // '(unnamed)',
            files       => $info->{files}
                              ? [ map { $_->{path} } @{ $info->{files} } ]
                              : [ $info->{name} ],
            total_size  => $info->{files}
                              ? sum(map { $_->{length} || 0 } @{ $info->{files} })
                              : $info->{length} || 0,
            source_path => $file_path,
            bucket      => $bucket,
            private     => $info->{private} ? 'Yes' : 'No',
        };
    }

    Logger::summary("[TorrentParser] Extracted "
        . scalar(keys %parsed_torrents)
        . " unique torrents (+ dupes/problems)");

    stop_timer("extract_metadata");
    report_bucket_distribution(\%bucket_counts);

    Utils::write_cache(\%parsed_torrents, 'parsed', $opts);
    return \%parsed_torrents;
}

sub report_bucket_distribution {
    my ($buckets) = @_;

    # Priority display order — comment tags show qBittorrent settings mapping
    my @priority_order = qw(
        completed_torrents   # "Copy .torrent files for finished downloads to:"
        bt_backup            # "~BT_backup" (internal qBt backup folder)
        downloaded_torrents  # "Copy .torrent files to:"
        kitchen_sink         # Everything else
    );

    # Calculate total
    my $total = 0;
    $total += $_ for values %$buckets;

    # Sort: priority first, then alphabetical for the rest
    my @sorted_buckets =
        grep { exists $buckets->{$_} } @priority_order,
        sort grep { my $b = $_; !grep { $_ eq $b } @priority_order } keys %$buckets;

    say "[INFO] Bucket Distribution:";
    for my $bucket (@sorted_buckets) {
        my $count = $buckets->{$bucket} // 0;
        my $pct   = $total > 0 ? sprintf("%5.1f", ($count / $total) * 100) : "  0.0";
        my $warn  = ($count == 0) ? " <-- WARNING: No torrents in this bucket" : "";

        # Mark unexpected buckets
        my $label = $bucket;
        unless (grep { $_ eq $bucket } @priority_order) {
            $label .= " [UNEXPECTED]";
        }

        # Tab alignment so things look clean
        printf "%-24s\t%6d\t(%5s%%)%s\n", $label, $count, $pct, $warn;
    }

    say ""; # Blank line for separation in logs
}

sub _process_bucket {
    my ($parsed, $bucket, $opts) = @_;
    my $dev_mode = $opts->{dev_mode};

    # Collect torrents in this bucket
    my @items = grep {
        ref($parsed->{$_}) eq 'HASH'
          && $parsed->{$_}{bucket}
          && $parsed->{$_}{bucket} eq $bucket
    } keys %$parsed;

    if (!@items) {
        Logger::info("[BUCKET] '$bucket' is empty, skipping.");
        return;
    }

    my $chunk = $dev_mode ? 5 : scalar @items;
    Logger::info("[BUCKET] Processing '$bucket' with " . scalar(@items) . " torrents (chunk=$chunk)");

    # Always do first batch
    my @batch = splice(@items, 0, $chunk);
    foreach my $ih (@batch) {
        my $torrent = $parsed->{$ih};
        Logger::info("[BUCKET:$bucket] Would load into API: $torrent->{source_path}");
    }
    Logger::info("[BUCKET:$bucket] Completed batch of " . scalar(@batch). "\n");

    return if $dev_mode;  # stop after first batch in dev mode

    # Otherwise process all
    while (@items) {
        my @next_batch = splice(@items, 0, $chunk);
        foreach my $ih (@next_batch) {
            my $torrent = $parsed->{$ih};
            Logger::info("[BUCKET:$bucket] Would load into API: $torrent->{source_path}");
        }
        Logger::info("[BUCKET:$bucket] Completed batch of " . scalar(@next_batch) . "\n");
    }
}

sub process_all_buckets {
    my ($parsed, $opts) = @_;
    my @priority_order = qw(
        completed_torrents
        bt_backup
        downloaded_torrents
        kitchen_sink
    );

    foreach my $bucket (@priority_order) {
        _process_bucket($parsed, $bucket, $opts);
    }
}






1;
