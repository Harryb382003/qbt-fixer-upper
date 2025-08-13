package TorrentParser;

use common::sense;
use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use Digest::SHA qw(sha1_hex);
use Bencode qw(bdecode bencode);
use File::Basename;
use JSON;
use List::Util qw(sum);
use Data::Dumper;
use Exporter 'import';

use lib 'lib/';
use Logger;
use Utils qw(start_timer stop_timer);


our @EXPORT_OK = qw(extract_metadata
                    match_by_date
                    );


my $CACHE_FILE = "cache/hash_cache.json";
my $problem_log_file = "logs/problem_torrents.json";

my %hash_cache;

if (-e $CACHE_FILE) {
    my $json = read_file($CACHE_FILE);
    %hash_cache = %{ decode_json($json) };
}

# sub match_by_date {
#     my ($self, $wiggle_minutes, $opts) = @_;
#     $wiggle_minutes ||= 10;
#
#     my $zombies_ref = $self->{zombies} || {};
#     return unless %$zombies_ref;
#
#     # Pull mdls metadata for all zombie source paths
#     my $zombie_mdls = Utils::get_mdls($zombies_ref);
#
#     my @matches;
#     my @no_added_on;
#     my @no_save_path;
#
#     foreach my $zombie_id (keys %$zombies_ref) {
#         my $zombie    = $zombies_ref->{$zombie_id};
#         my $name      = $zombie->{name}       // 'UNKNOWN';
#         my $path      = $zombie->{save_path}  // 'UNKNOWN PATH';
#         my $added_on  = $zombie->{added_on};
#
#         say "$name ($path)";
#
#         unless ($added_on) {
#             push @no_added_on, $zombie;
#             next;
#         }
#
#         # mdls info for this torrent file
#         my $source_path = $zombie->{source_path} // '';
#         my $mdls_info   = $zombie_mdls->{$source_path} || {};
#         my $created     = $mdls_info->{kMDItemFSCreationDate} // '';
#         my $added       = $mdls_info->{kMDItemDateAdded}      // '';
#
#         my $matched = 0;
#         if ($added && abs(str2epoch($added) - $added_on) <= ($wiggle_minutes * 60)) {
#             say "    match (added)";
#             $matched++;
#         }
#         if ($created && abs(str2epoch($created) - $added_on) <= ($wiggle_minutes * 60)) {
#             say "    match (creation)";
#             $matched++;
#         }
#
#         if ($matched) {
#             push @matches, $zombie;
#         } else {
#             push @no_save_path, $zombie;
#         }
#     }
#
#     Logger::info("[MATCH] $wiggle_minutes minute window — "
#         . scalar(@matches) . " matches, "
#         . scalar(@no_added_on) . " with no added_on, "
#         . scalar(@no_save_path) . " with no save_path match");
#
#     return {
#         matches            => \@matches,
#         no_added_on        => \@no_added_on,
#         no_save_path       => \@no_save_path,
#         matches_count      => scalar(@matches),
#         no_added_on_count  => scalar(@no_added_on),
#         no_save_path_count => scalar(@no_save_path),
#     };
# }

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub extract_metadata {
    my ($self, $torrent_files, $opts) = @_;
#say "[DEBUG] extract_metadata got: " . Dumper($torrent_files);
    my %parsed_torrents;
    my %bucket_counts;

    foreach my $file_path (@$torrent_files) {
        my $info = bdecode_file($file_path);
        next unless $info;

        # --- Assign bucket ---
        my $bucket;
        if ($file_path =~ m{Completed_torrents}i) {
            $bucket = 'completed_torrents'; # "Copy .torrent files for finished downloads to:"
        }
        elsif ($file_path =~ m{BT_backup}i) {
            $bucket = 'bt_backup';          # ~BT_backup folder
        }
        elsif ($file_path =~ m{Downloaded_torrents}i) {
            $bucket = 'downloaded_torrents'; # "Copy .torrent files to:"
        }
        else {
            $bucket = 'kitchen_sink';        # Everything else
        }
        $bucket_counts{$bucket}++;

        # --- Build torrent record ---
        $parsed_torrents{$file_path} = {
            name        => $info->{name} // '(unnamed)',
            files       => $info->{files}
                              ? [ map { $_->{path} } @{ $info->{files} } ]
                              : [ $info->{name} ],
            total_size  => $info->{files}
                              ? sum(map { $_->{length} || 0 } @{ $info->{files} })
                              : $info->{length} || 0,
            raw         => $info,
            source_path => $file_path,
            bucket      => $bucket,
            private     => $info->{private} ? 'Yes' : 'No',
        };
    }

    # --- Report bucket distribution ---
    report_bucket_distribution(\%bucket_counts);

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


sub bdecode_file {
	Logger::debug("#	bdecode_file");
  my ($file_path) = @_;
  my $raw;

  open my $fh, '<:raw', $file_path or do {
    Logger::warn("Cannot open $file_path: $!");
    return undef;
  };

  {
    local $/;
    $raw = <$fh>;
  }
  close $fh;

  my $decoded;
  eval { $decoded = bdecode($raw); };

  return $decoded;
}

# sub _log_problem_torrent {
#   my ($name, $error) = @_;
#
#   my $entry = {
#     name    => $name,
#     error   => $error,
#     time    => scalar localtime,
#   };
#
#   append_file($problem_log_file, encode_json($entry) . "\n");
# }

1;
