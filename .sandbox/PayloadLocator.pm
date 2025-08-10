package PayloadLocator;

use common::sense;
use File::Find;
use File::Spec;
use Cwd qw(abs_path);
use Logger;

our @EXPORT_OK = qw(build_file_map filter_file_map_by_torrents);
use Exporter qw(import);
#
# sub build_file_map {
#     my ($opts, $prefs) = @_;
#     my %file_map;
#
#     # Only scan filesystem if explicitly allowed
#     unless ($opts->{enable_filesystem_scan}) {
#         Logger::warn("Filesystem scanning disabled. Skipping file discovery.");
#         return \%file_map;
#     }
#
#     my $root = $opts->{torrent_scan_root} || '/';
#     Logger::debug("[DEBUG] Building file map from: $root");
#
#     my @files;
#     find({
#         wanted => sub {
#             return unless -f $_;
#             my $abs = abs_path($File::Find::name);
#             push @files, $abs if $abs;
#         },
#         no_chdir => 1
#     }, $root);
#
#     my $excluded_count = 0;
#     my @excluded = @{$opts->{excluded} || []};
#
#     Logger::trace("[TRACE] Exclusion paths: @excluded");
#
#     my @filtered_files;
#     foreach my $file (@files) {
#         my $excluded = 0;
#         foreach my $ex (@excluded) {
#             if (index($file, $ex) == 0) {
#                 $excluded = 1;
#                 $excluded_count++;
#                 last;
#             }
#         }
#         push @filtered_files, $file unless $excluded;
#     }
#
#     @files = @filtered_files;
#
#     Logger::info("[DEBUG] Files discovered before exclusion: " . scalar(@filtered_files) + $excluded_count);
#     Logger::info("[DEBUG] Files excluded due to path rules: $excluded_count");
#     Logger::info("[DEBUG] Final included files: " . scalar(@files));
#
#     foreach my $file (@files) {
#         my $size = -s $file;
#         push @{$file_map{$size}}, $file if defined $size;
#     }
#
#     return \%file_map;
# }

sub filter_file_map_by_torrents {
    my ($file_map, $torrent_data) = @_;
    my %used_files;

    foreach my $torrent (values %$torrent_data) {
        foreach my $rel_path (@{ $torrent->{files} }) {
            my $key = ref($rel_path) eq 'ARRAY' ? join('/', @$rel_path) : $rel_path;
            $used_files{$key} = 1;
        }
    }

    my %filtered;
    foreach my $size (keys %$file_map) {
        foreach my $file (@{$file_map->{$size}}) {
            my ($vol, $dir, $file_only) = File::Spec->splitpath($file);
            next unless $used_files{$file_only};
            push @{$filtered{$size}}, $file;
        }
    }

    return \%filtered;
}

1;
