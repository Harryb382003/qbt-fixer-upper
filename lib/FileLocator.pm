package FileLocator;

use common::sense;
use Data::Dumper;

use File::Find;
use Cwd qw(abs_path);
use File::Basename;
use File::Spec;
use File::Path qw(make_path);
# use Time::HiRes qw(gettimeofday tv_interval);

use lib 'lib';
use Logger;
use Utils qw(start_timer stop_timer sprinkle);

use Exporter 'import';
our @EXPORT_OK = qw(find_l_torrents);

sub locate_l_torrents {
    my ($opts) = @_;   # standard repo pattern — whole opts hashref

    Logger::debug("#\tlocate_l_torrents");
    start_timer("find_torrents");

    my @results;
    my $has_mdfind = `which mdfind 2>/dev/null` && $? == 0;

    if ($has_mdfind) {
        Logger::debug("Using mdfind to locate torrents");
        @results = `mdfind 'kMDItemFSName == "*.torrent"cd' 2>/dev/null`;
        chomp @results;
    } else {
        # no code has been written to use File::Find or any other tool to locate torrents
        Logger::error("Using File::Find to locate torrents");
    }
    Logger::info("[MAIN] Located " . scalar(@results) . " torrents from filesystem search");
    stop_timer("find_torrents");
    return @results;
}

1;
