
package DedupeEngine;

use common::sense;
use Digest::SHA qw(sha1_hex);
use File::Basename;
use Logger qw(init info);

# # Main entry point
# sub deduplicate {
#     my ($file_map, $opts) = @_;
#     my %dedupe_candidates;
#     my @non_duplicates;
#
#     # Phase 1: Partition by file size
#     foreach my $size (keys %$file_map) {
#         my $group = $file_map->{$size};
#         if (@$group > 1) {
#             $dedupe_candidates{$size} = $group;
#         } else {
#             push @non_duplicates, $group->[0];
#         }
#     }
#
#     Logger::info("[DEDUP] Singleton (non-duplicate) files retained: " . scalar(@non_duplicates));
#     Logger::info("[DEDUP] Buckets with potential duplicates: " . scalar(keys %dedupe_candidates));
#
#     my @clusters;
#
#     # Phase 2: Within-size grouping by quick hash
#     foreach my $size (keys %dedupe_candidates) {
#         my %quick_groups;
#         foreach my $file (@{ $dedupe_candidates{$size} }) {
#             my $fp = quick_fingerprint($file, $opts->{quick_bytes} || 65536);
#             push @{ $quick_groups{$fp} }, $file if $fp;
#         }
#
#         # Phase 3: Confirm by full hash within each quick hash group
#         foreach my $fp (keys %quick_groups) {
#             my @group = @{ $quick_groups{$fp} };
#             next unless @group > 1;
#
#             my %final;
#             foreach my $file (@group) {
#                 my $full_hash = full_hash($file);
#                 push @{ $final{$full_hash} }, $file if $full_hash;
#             }
#
#             foreach my $digest (keys %final) {
#                 my @set = @{ $final{$digest} };
#                 push @clusters, \@set if @set > 1;
#             }
#         }
#     }
#
#     Logger::info("[DEDUP] Confirmed duplicate groups: " . scalar(@clusters));
#     return {
#         duplicates     => \@clusters,
#         non_duplicates => \@non_duplicates,
#     };
# }
#
# sub quick_fingerprint {
#     my ($path, $bytes) = @_;
#     open my $fh, '<', $path or return undef;
#     binmode $fh;
#     my $chunk;
#     my $n = read($fh, $chunk, $bytes);
#     close $fh;
#     return sha1_hex($chunk);
# }
#
# sub full_hash {
#     my ($path) = @_;
#     open my $fh, '<', $path or return undef;
#     binmode $fh;
#     local $/;
#     my $data = <$fh>;
#     close $fh;
#     return sha1_hex($data);
# }
#
# sub deduplicate_by_infohash {
#     my ($export_torrents, $other_torrents) = @_;
#
#     # Create a lookup hash of known (trusted) infohashes
#     my %export_infohashes = map { $_ => 1 } keys %$export_torrents;
#
#     my @duplicates;
#
#     foreach my $infohash (keys %$other_torrents) {
#         if ($export_infohashes{$infohash}) {
#             push @duplicates, {
#                 duplicate => $other_torrents->{$infohash},
#                 reference => $export_torrents->{$infohash},
#                 infohash  => $infohash,
#                 reason    => 'Matched metadata to known exported torrent'
#             };
#         }
#     }
#
#     return \@duplicates;
# }

1;
