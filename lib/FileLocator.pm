package FileLocator;

use common::sense;
use File::Find;
use Cwd qw(abs_path);
use File::Basename;
use File::Spec;
use File::Path qw(make_path);
use Logger;
use Time::HiRes qw(gettimeofday tv_interval);
use lib 'lib/';
use Utils qw(start_timer stop_timer);

use Exporter 'import';
our @EXPORT_OK = qw(find_l_torrents);


sub locate_l_torrents {
	Logger::debug("#	locate_l_torrents");
    start_timer("find_torrents");

    my ($primary_dir, $export_dirs_ref) = @_;
    my @results;
    my $has_mdfind = `which mdfind 2>/dev/null` && $? == 0;

    if ($has_mdfind) {
        Logger::debug("Using mdfind for fast file discovery");
        @results = `mdfind 'kMDItemFSName == "*.torrent"cd' 2>/dev/null`;
        chomp @results;
    } elsif ($main::opts{allow_fallback}) {
        Logger::debug("mdfind unavailable — falling back to File::Find");
        @results = _scan_with_file_find($primary_dir);
    } else {
        Logger::debug("[SKIP] File scan skipped — no fast method permitted (mdfind unavailable, fallback disabled).");
        return ();
    }

    stop_timer("find_torrents");
    Logger::debug("Found .torrent files: " . scalar(@results));
    return (@results);
}

#
# sub _scan_with_file_find {
#     my ($root) = @_;
#     my @found;
#
#     find({
#         wanted => sub {
#             my $abs = abs_path($File::Find::name);
#             push @found, $abs if defined $abs && -f $abs && $abs =~ /\.torrent$/i;
#         },
#         no_chdir => 1
#     }, $root);
#
#     return @found;
# }

# sub filter_excluded_paths {
#     my ($files_ref, $excluded_ref) = @_;
#     my @excluded = @$excluded_ref;
#     Logger::trace("[TRACE] Exclusion paths: " . join(" ", @excluded));
#
#     my @filtered;
#     my $excluded_count = 0;
#     foreach my $f (@$files_ref) {
#         my $skip = 0;
#         foreach my $ex (@excluded) {
#             if (index($f, $ex) == 0) {
#                 $excluded_count++;
#                 $skip = 1;
#                 last;
#             }
#         }
#         push @filtered, $f unless $skip;
#     }
#
#     Logger::debug("[DEBUG] Files excluded due to path rules: $excluded_count");
#     return @filtered;
# }


1;