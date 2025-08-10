
package Sieve;

use common::sense;
use Exporter 'import';
use Utils qw(start_timer stop_timer);

our @EXPORT_OK = qw(
  filter_by_export_dirs
  filter_loaded_infohashes
);
#
# sub filter_by_export_dirs {    # SIEVE 1, filter by export directories
#   Logger::info("filter_by_export_dirs");
#   start_timer("sieve 1: filter_by_export_dirs");
#
#   my %opts;
#   my ($all, $parsed_all, $opts) = @_;
#   my ($qb, %reference_infohashes, %torrent_data);
#   foreach my $infohash (keys %$parsed_all)
#   {
#     my $source_path = $parsed_all->{$infohash}{source_path} // '';
#     if (grep { $source_path =~ /^\Q$_/ } $opts{export_dirs})
#     {
#       $reference_infohashes{$infohash} = 1;
#     }
#   }
#
#   my $remainder = $all - (keys %reference_infohashes);
#   Logger::debug(  "There were "
#                 . scalar(keys %reference_infohashes)
#                 . " qBittorrent-managed torrents filtered out");
#   Logger::info("There are now " . $remainder . " remaining");
#   stop_timer("sieve 1: filter_by_export_dirs");
# #   if ($opts{dev_mode})
# #   {
# #     DevTools::dev_compare_qbt_vs_exports_detailed($qb, \%opts);
# #     DevTools::verify_reference_infohashes($parsed_all, $remainder);
# #   }
#   return \%reference_infohashes;
# }
#
# sub filter_loaded_infohashes {  # Sieve 2
#     my ($remaining_candidates, $qbt_loaded_infohashes) = @_;
#
#     Utils::start_timer("Sieve 2");
#     Logger::info("[INFO] Filtering torrents already loaded in qBittorrent (by infohash)...");
#
#     my %filtered;
#     my $filtered_count = 0;
# say "scalar(keys)remaining = " . scalar(keys %$remaining_candidates);
# say "scalar(keys)qbt_loaded_infohashes = " . scalar(keys %$qbt_loaded_infohashes);
#     foreach my $ih (keys %$remaining_candidates) {
#         if ($qbt_loaded_infohashes->{$ih}) {
# say
# say "MATCH!";
#
#             $filtered_count++;
# say $filtered_count . " = $qbt_loaded_infohashes->{$ih}\n";
#             next;
#         }
#         $filtered{$ih} = $remaining_candidates->{$ih};
#     }
#
#     Logger::info("[SIEVE 2] Torrents filtered (already loaded): $filtered_count");
#     Logger::info("[SIEVE 2] Remaining after deduplication: " . scalar(keys %filtered));
#     Utils::stop_timer("Sieve 2");
#
#     return \%filtered;
# }
#
# sub bucket_by_infohash {
#   my ($remaining_candidates) = @_;
#
#   Logger::info("[INFO] Grouping remaining candidates by infohash...");
#   start_timer("sieve 3: bucket_by_infohash");
#
#   my %buckets;
#
#   foreach my $ih (keys %$remaining_candidates)
#   {
#     my $torrent = $remaining_candidates->{$ih};
#
#     # Start bucket if none
#     if (!$buckets{$ih})
#     {
#       $buckets{$ih} = {keep => $torrent, duplicates => [], normalize => 0,};
#     }
#     else
#     {
#       push @{$buckets{$ih}->{duplicates}}, $torrent;
#     }
#
#     # Mark if name looks like an infohash — we'll want to normalize this later
#     if ($torrent->{name} =~ /^[a-f0-9]{40}$/i)
#     {
#       $buckets{$ih}->{normalize} = 1;
#     }
#   }
#
#   Logger::info("[SIEVE 3] Buckets created: " . scalar(keys %buckets));
#   my $total_dupes = 0;
#   $total_dupes += scalar(@{$buckets{$_}{duplicates}}) for keys %buckets;
#   Logger::debug("[SIEVE 3] Total duplicates flagged: $total_dupes");
#
#   stop_timer("sieve 3: bucket_by_infohash");
#   return \%buckets;
# }

=pod
sub filter_known_infohashes {    # SIEVE 2
  start_timer("sieve 2");
  my ($all_data, $reference) = @_;

  Utils::start_timer("sieve 2");
  Logger::info("[INFO] Filtering candidates based on known infohashes...");

  my $filtered_out = 0;
  my %remaining;

  foreach my $ih (keys %$all_data)
  {
    if ($reference->{$ih})
    {
      $filtered_out++;
      next;
    }
    $remaining{$ih} = $all_data->{$ih};
  }

  my $remaining_count = scalar keys %remaining;
  Logger::info(
               sprintf("[SIEVE 2] Infohash dedup — removed: %d, remaining: %d",
                       $filtered_out, $remaining_count));

  Utils::stop_timer("sieve 2");
  return \%remaining;
}

sub is_infohash_name {
    my ($name) = @_;
    return $name =~ /^[a-f0-9]{40}$/i ? 1 : 0;
}

sub verify_reference_infohashes {
  my ($parsed_all, $reference_infohashes, $opts) = @_;
  return unless $opts->{dev_mode};

  Logger::info("[DEV] --- Verifying reference infohash coverage ---");

  my @export_refs;
  foreach my $ih (keys %$parsed_all) {
    my $source = $parsed_all->{$ih}{source_path} // '';
    if (grep { $source =~ /^\Q$_/ } @{ $opts->{export_dirs} }) {
      push @export_refs, $ih;
    }
  }

  my $expected = scalar @export_refs;
  my $actual   = scalar keys %$reference_infohashes;

  Logger::info("[DEV] .torrent files found in export_dir(s): $expected");
  Logger::info("[DEV] Infohashes matched into reference set: $actual");

  if ($actual < $expected) {
    my $delta = $expected - $actual;
    Logger::warn("[DEV] ⚠️ $delta torrent(s) in export_dir not matched into reference infohash set");
  } elsif ($actual > $expected) {
    Logger::warn("[DEV] ⚠️ Unexpected surplus in reference infohash set (possible leakage)");
  } else {
    Logger::info("[DEV] ✅ Reference infohash set matches export_dir .torrent count");
  }
}

sub isolate_reference_infohashes {
    my ($parsed_all, $export_dirs) = @_;

    Utils::start_timer("Sieve 3: isolate_reference_infohashes");
    Logger::info("[INFO] Identifying torrents managed by qBittorrent...");

    my %reference;
    foreach my $ih (keys %$parsed_all) {
        my $source_path = $parsed_all->{$ih}{source_path} // '';
        if (grep { $source_path =~ /^\Q$_/ } @$export_dirs) {
            $reference{$ih} = 1;
        }
    }

    Logger::debug("qBittorrent-managed torrents: " . scalar keys %reference);
    Utils::stop_timer("sieve 1: isolate_reference_infohashes");

    return \%reference;
}

sub is_infohash_name {
    my ($name) = @_;
    return $name =~ /^[a-f0-9]{40}$/i ? 1 : 0;
}

=cut

1;
