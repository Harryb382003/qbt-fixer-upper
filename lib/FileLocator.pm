package FileLocator;

use common::sense;
use Data::Dumper;

use File::Find;
use Cwd qw(abs_path);
use File::Basename;
use File::Spec;
use File::Path qw(make_path);
use Time::HiRes qw(gettimeofday tv_interval);

use lib 'lib';
use Logger;
use Utils qw(start_timer stop_timer);

use Exporter 'import';
our @EXPORT_OK = qw(find_l_torrents);

sub locate_l_torrents {
    Logger::debug("#\tlocate_l_torrents");

    start_timer("find_torrents");

    my ($primary_dir, $export_dirs_ref) = @_;

    say "[FileLocator.pm line " . __LINE__ . "] $primary_dir = " . basename($primary_dir);
    say "[FileLocator.pm line " . __LINE__ . "] $export_dirs_ref = " . Dumper($export_dirs_ref) if $ENV{DEBUG};

    my @results;
    my $has_mdfind = `which mdfind 2>/dev/null` && $? == 0;

    if ($has_mdfind) {
        Logger::debug("Using mdfind to locate torrents");
        say "[FileLocator.pm line " . __LINE__ . "] Using mdfind search in $primary_dir";
    } else {
        Logger::debug("Using File::Find to locate torrents");
        say "[FileLocator.pm line " . __LINE__ . "] Using File::Find search in $primary_dir";
    }

    stop_timer("find_torrents");
    return \@results;
}

1;
