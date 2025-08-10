package Backup;

use common::sense;
use File::Path qw(make_path);
use File::Copy;
use File::Basename;
use File::Slurp;
use POSIX qw(strftime);
#
# sub create_backup {
#     my $timestamp = strftime "%Y%m%d-%H%M%S", localtime;
#     my $backup_dir = "backup/$timestamp";
#     make_path($backup_dir);
#
#     # Example: backup qBittorrent data and .torrent files
#     my @sources = (
#         "$ENV{HOME}/.local/share/qBittorrent",  # Linux default
#         "$ENV{HOME}/Library/Application Support/qBittorrent",  # macOS
#         "torrents"  # assumed local .torrent dir
#     );
#
#     foreach my $src (@sources) {
#         next unless -e $src;
#         my $dest = "$backup_dir/" . basename($src);
#         system("cp -a '$src' '$dest'") == 0
#             or warn "Backup failed for $src\n";
#     }
#
#     print "Backup completed at $backup_dir\n";
# }

1;
