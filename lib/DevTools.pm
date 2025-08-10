
package DevTools;

use common::sense;
use File::Basename;
use Logger;

use Exporter 'import';
our @EXPORT_OK = qw(
	dev_compare_qbt_vs_exports_detailed
	verify_reference_infohashes
	);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );
#
# sub dev_compare_qbt_vs_exports_detailed {
#     my ($qb, $opts) = @_;
#     return unless $opts->{dev_mode};
#
#     my $export_dirs = $opts->{export_dirs};
#     return unless $export_dirs && ref $export_dirs eq 'ARRAY';
#
#     say "\n--- [DEV-MODE] qBittorrent vs Export Directory Comparison ---";
#
#     my $torrent_info = $qb->get_torrents();
#     my @qbt_names = map { $_->{name} } values %$torrent_info;
#     my %qbt_name_set = map { $_ => 1 } @qbt_names;
#
#     my $infohash_like = grep { /^[a-fA-F0-9]{40}$/ } @qbt_names;
#     Logger::info("[DEV] qBittorrent torrents       : " . scalar(@qbt_names));
#     Logger::info("[DEV] qBittorrent Infohash-style torrent names: $infohash_like");
#
#     foreach my $dir (@$export_dirs) {
#         next unless -d $dir;
#         opendir(my $dh, $dir) or do {
#             Logger::warn("[DEV] Cannot open export dir: $dir");
#             next;
#         };
#
#         my @torrent_files = grep { /\.torrent$/i } readdir($dh);
#         closedir($dh);
#
#         my @names = map { s/\.torrent$//r } @torrent_files;
#         my %name_set = map { $_ => 1 } @names;
#
#         my $intersection = grep { $qbt_name_set{$_} } @names;
#
#         Logger::info("[DEV] Export Dir: $dir holds " . scalar(@torrent_files) . " files" );
# #         Logger::info("[DEV]   .torrent files: " . scalar(@torrent_files));
#         Logger::info(
# 					"[DEV]  $intersection names match in qBt having a delta of "
# 					. (scalar(@torrent_files) - $intersection) );
#     }
# }
#
# # lib/DevTools.pm
#
# sub verify_reference_infohashes {
#     my ($parsed_all, $reference_infohashes) = @_;
#     my $count_verified = 0;
#
#     foreach my $ih (keys %$reference_infohashes) {
#         $count_verified++ if exists $parsed_all->{$ih};
#     }
#
#     Logger::info("[DEV] Verified infohashes (match in parsed set): $count_verified / " . scalar(keys
# %$reference_infohashes));
# }

1;
