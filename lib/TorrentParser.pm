
package TorrentParser;

use common::sense;
use Data::Dumper;

use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use Digest::SHA qw(sha1_hex);
use File::Basename qw(basename);
use List::Util qw(sum);
use Bencode qw(bdecode bencode);
use JSON;
use Exporter 'import';

use lib 'lib/';
use Logger;
use Utils qw(start_timer stop_timer sprinkle);


our @EXPORT_OK = qw(
    extract_metadata
    match_by_date
    process_all_infohashes
    normalize_filename
    report_collision_groups

);

my $CACHE_FILE = "cache/hash_cache.json";
my $problem_log_file = "logs/problem_torrents.json";
my $colliders = {};   # tracks filename collisions across all torrents

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
    my ($self) = @_;

    my $opts  = $self->{opts};
    my @files = @{ $self->{all_torrents} };

    my %seen;
    my %parsed_by_infohash;
    my %parsed_by_bucket;
    my %bucket_uniques;
    my %bucket_dupes;
    my %bucket_groups;      # grouped collision tracking
    my $intra_dupe_count = 0;
    my $rename_count     = 0;
    my $collision_count  = 0;

    foreach my $file_path (@files) {
        Logger::debug("[TorrentParser] Processing $file_path");

        # --- Read and decode torrent ---
        my $raw;
        {
            local $/;
            open my $fh, '<:raw', $file_path or do {
                Logger::error("[TorrentParser] Failed to open $file_path: $!");
                next;
            };
            $raw = <$fh>;
            close $fh;
        }

        my $info;
        eval { $info = bdecode($raw); 1 } or do {
            Logger::error("[TorrentParser] Failed to bdecode $file_path: $@");
            next;
        };

        # --- Compute infohash ---
        my $infohash = sha1_hex(Bencode::bencode($info->{info}));
        my $torrent_name = $info->{info}{name} // basename($file_path);

        # --- Bucket assignment ---
        my $bucket = _assign_bucket($file_path, $opts);

        # --- Build metadata ---
        my $metadata = {
            infohash    => $infohash,
            name        => $torrent_name,
            files       => $info->{files}
                             ? [ map { $_->{path} } @{ $info->{files} } ]
                             : [ $torrent_name ],
            total_size  => $info->{files}
                             ? sum(map { $_->{length} || 0 } @{ $info->{files} })
                             : $info->{length} || 0,
            source_path => $file_path,
            bucket      => $bucket,
            private     => $info->{private} ? 'Yes' : 'No',
            tracker     => $info->{announce} // '',
            comment     => $info->{comment}  // '',
        };

        # --- TODO: translation hook ---
        if (my $translation = $opts->{translation}) {   # e.g. supplied externally
            if ($metadata->{comment}) {
                $metadata->{comment} .= "\nEN: $translation";
            } else {
                $metadata->{comment} = "EN: $translation";
            }
        }

        # --- Dupe / authoritative handling ---
        if (exists $seen{$infohash}) {
            $intra_dupe_count++;
            $bucket_dupes{$bucket}++;
            next;
        }

        # --- Collision case study (grouped by bucket) ---
        $bucket_groups{$bucket}{$torrent_name . ".torrent"} //= [];
        push @{ $bucket_groups{$bucket}{$torrent_name . ".torrent"} }, $metadata;

        $seen{$infohash} = 1;
        $parsed_by_infohash{$infohash} = $metadata;
        push @{ $parsed_by_bucket{$bucket} }, $metadata;
        $bucket_uniques{$bucket}++;
    }

    Logger::summary("[SUMMARY] [BUCKETS]");
    for my $bucket (sort keys %bucket_uniques) {
        my $u = $bucket_uniques{$bucket} // 0;
        my $d = $bucket_dupes{$bucket}   // 0;
        my $t = $u + $d;
        Logger::summary(sprintf("   %-20s  total=%6d  uniques=%6d  dupes=%6d",
            $bucket, $t, $u, $d));
    }

    return {
        by_infohash => \%parsed_by_infohash,
        by_bucket   => \%parsed_by_bucket,
        uniques     => \%bucket_uniques,
        dupes       => \%bucket_dupes,
        renamed     => $rename_count,
        collisions  => \%bucket_groups,
        intra_dupes => $intra_dupe_count,
    };
}

sub normalize_filename {
    my ($meta, $opts) = @_;
    my $old_path     = $meta->{source_path};
    my $torrent_name = $meta->{name};
    my $tracker      = $meta->{tracker};
    my $comment      = $meta->{comment};

    # Always make a safe filename
    my $safe_name = $torrent_name;
    $safe_name .= ".torrent" unless $safe_name =~ /\.torrent$/i;

    my $dir      = dirname($old_path);
    my $new_path = "$dir/$safe_name";

    # Nothing to do if same
    return $old_path if $old_path eq $new_path;

    # If not normalizing, log intent and bail
    unless ($opts->{normalize}) {
        Logger::info("\n[normalize_filename] Would normalize: \n\t$old_path → \n\t $new_path");
        return $old_path;
    }

    # Try rename
    if (move($old_path, $new_path)) {
        Logger::info("[normalize_filename] Renamed: \n\t$old_path → \n\t$new_path");
        return $new_path;
    } else {
        Logger::warn("[normalize_filename] Failed to rename:\n\t$old_path →\n\t $new_path: $!");
        return $old_path;
    }
}

sub report_collision_groups {
    my ($bucket_groups) = @_;
    my $collision_groups = 0;

    # Specifically target kitchen_sink (or any bucket you care about)
    if (exists $bucket_groups->{kitchen_sink}) {
        for my $name (sort keys %{ $bucket_groups->{kitchen_sink} }) {
            my $entries = $bucket_groups->{kitchen_sink}{$name};

            if (@$entries > 1) {
                $collision_groups++;
                Logger::info("\n[COLLIDER] $name");
                Logger::info("\t$_->{source_path}") for @$entries;
            }
        }
    }

    Logger::summary("[SUMMARY] Filename collision groups observed:\t$collision_groups");
}
sub process_all_infohashes {
    my ($parsed, $opts) = @_;
    Logger::info("\n[MAIN] Starting process_all_infohashes()");

    Logger::info("Parsed keys: " . join(", ", keys %$parsed));
    my $infohashes = $parsed->{by_infohash};
    my $count = scalar keys %$infohashes;
    Logger::info(" [MAIN] Found $count unique torrents to process");

    foreach my $infohash (sort keys %$infohashes) {
        my $meta = $infohashes->{$infohash};

#         Logger::info(__LINE__ . " [INFOHASH] Processing $infohash "
#             . "($meta->{bucket}), $meta->{name}");

        # --- Step 1: Verify source .torrent file still exists ---
        unless (-f $meta->{source_path}) {
            Logger::warn(__LINE__ . "[INFOHASH:$infohash] Missing source file: $meta->{source_path}");
            next;
        }

        # --- Step 2: Payload sanity checks (Utils::sanity_check_payload) ---
        my $payload_ok = Utils::sanity_check_payload($meta);
        unless ($payload_ok) {
            Logger::warn(__LINE__ . "[INFOHASH:$infohash] Payload sanity check failed, skipping");
            next;
        }

#         # --- Step 3: Decide save_path ---
#         my $save_path = Utils::determine_save_path($meta, $opts);
#         Logger::debug("[INFOHASH:$infohash] save_path = "
#             . (defined $save_path ? $save_path : "(qBittorrent default)"));
#
#         # --- Step 4: Call qBittorrent API (stub for now) ---
#         Logger::info("[INFOHASH:$infohash] Would call QBT add_torrent: "
#             . "source=$meta->{source_path}, save_path="
#             . (defined $save_path ? $save_path : "QBT-default")
#             . ", category=" . ($meta->{bucket} // "(none)"));
#
#         # TODO: $qb->add_torrent($meta->{source_path}, $save_path, $meta->{bucket});
    }

    Logger::info("[MAIN] Finished process_all_infohashes()");
}

# --- internal helpers ---
sub _assign_bucket {
    my ($path, $opts) = @_;

    # Check against each configured export_dir_fin
    for my $cdir (@{ $opts->{export_dir_fin} }) {
        if (index($path, $cdir) != -1) {
            return basename($cdir);  # dynamic bucket name
        }
    }

    # Check against each configured export_dir
    for my $ddir (@{ $opts->{export_dir} }) {
        if (index($path, $ddir) != -1) {
            return basename($ddir);  # dynamic bucket name
        }
    }

    # BT_backup (hardcoded, qBittorrent internal)
    return 'BT_backup' if $path =~ /BT_backup/;

    # Default fallback
    return 'kitchen_sink';
}



=pod


sub _collision_handler {
    my ($meta, $opts, $colliders) = @_;
    return if !$opts->{normalize};   # 🚫 skip silently if switch is off

    my $bucket = $meta->{bucket};
    my $path   = $meta->{source_path};
    my $base   = basename($path);

    # init counters once
    $colliders->{case_study} //= {
        authoritative_safe      => 0,
        kitchen_sink_safe       => 0,
        kitchen_sink_normalized => 0,
        kitchen_sink_manual     => 0,
        kitchen_sink_missing    => 0,
    };

    # --- Authoritative buckets (qBittorrent managed) ---
    if ($bucket ne 'kitchen_sink') {
        Logger::summary("[NORMALIZE] Authoritative bucket ($bucket) → safe: $base");
        $colliders->{case_study}{authoritative_safe}++;
        return "authoritative_safe";
    }

    # --- Kitchen sink collisions ---
    if (-e $path) {
        my $normalized = Utils::normalize_filename($meta, $colliders);

        if ($normalized ne $path) {
            if (-e $normalized) {
                Logger::summary("[NORMALIZE] KS collision escalation failed (target exists) → manual: $normalized");
                push @{ $colliders->{manual} }, $path;
                $colliders->{case_study}{kitchen_sink_manual}++;
                return "kitchen_sink_manual";
            }
            Logger::summary("[NORMALIZE] KS collision normalized: $base → $normalized");
            $colliders->{case_study}{kitchen_sink_normalized}++;
            return "kitchen_sink_normalized";
        }
        else {
            Logger::summary("[NORMALIZE] KS no collision, safe: $base");
            $colliders->{case_study}{kitchen_sink_safe}++;
            return "kitchen_sink_safe";
        }
    }

    Logger::summary("[NORMALIZE] KS missing source file → ignored: $base");
    $colliders->{case_study}{kitchen_sink_missing}++;
    return "kitchen_sink_missing";
}





# ==========================
# Bucket processing
# ==========================

# sub process_all_buckets {
#     my ($parsed, $opts) = @_;
#
#     # Only buckets, skip by_infohash
#     my $buckets = $parsed->{by_bucket};
#
#     foreach my $bucket (keys %$buckets) {
#         my $bucket_data = $buckets->{$bucket};
#         my $count       = scalar keys %$bucket_data;
#
#         Logger::info("\n[BUCKET] Processing '$bucket' with $count torrents");
#
#         _process_bucket($bucket, $bucket_data, $opts);
#     }
# }



# sub _process_bucket {
#     my ($bucket, $bucket_data, $opts) = @_;
#
#     # dev_mode controls chunking
#     my $dev_mode = $opts->{dev_mode};
#     my $chunk    = $dev_mode ? 5 : scalar keys %$bucket_data;
#
#     my @files = keys %$bucket_data;
#     my $count = 0;
#
#     while (@files) {
#         my @batch = splice(@files, 0, $chunk);
#
#         foreach my $file_path (@batch) {
#             Logger::info("194[BUCKET:$bucket] Would load into API: $file_path");
#             # TODO: replace this stub with actual add_torrent call later
#         }
#
#         Logger::info("[198 BUCKET:$bucket] Completed batch of " . scalar(@batch));
#         last if $dev_mode;  # stop after first batch if dev_mode enabled
#     }
# }

=cut


1;
