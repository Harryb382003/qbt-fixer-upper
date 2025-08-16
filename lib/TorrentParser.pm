
package TorrentParser;

use common::sense;
use Data::Dumper;

use File::Slurp qw(read_file write_file);
use File::Path qw(make_path);
use Digest::SHA qw(sha1_hex);
use Bencode qw(bdecode bencode);
use File::Basename;
use JSON;
use List::Util qw(sum);
use Exporter 'import';

use lib 'lib/';
use Logger;
use Utils qw(start_timer stop_timer);


our @EXPORT_OK = qw(
    extract_metadata
    match_by_date
);

my $CACHE_FILE = "cache/hash_cache.json";
my $problem_log_file = "logs/problem_torrents.json";

my %hash_cache;

if (-e $CACHE_FILE) {
    my $json = read_file($CACHE_FILE);
    %hash_cache = %{ decode_json($json) };
}

# --- PUBLIC ---

sub extract_metadata {
    my ($self, $torrent_files, $opts) = @_;
    say "[TorrentParser line " . __LINE__ . "] $torrent_files" if $opts->{debug};

    my %parsed_torrents;
    my %bucket_counts;

    foreach my $file_path (@$torrent_files) {
        my $info = Utils::bdecode_file($file_path);
        next unless $info;

        # --- Assign bucket ---
        my $bucket;
        if ($file_path =~ m{Completed_torrents}i) {
            $bucket = 'completed_torrents';
        }
        elsif ($file_path =~ m{BT_backup}i) {
            $bucket = 'bt_backup';
        }
        elsif ($file_path =~ m{Downloaded_torrents}i) {
            $bucket = 'downloaded_torrents';
        }
        else {
            $bucket = 'kitchen_sink';
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

    report_bucket_distribution(\%bucket_counts);

    Utils::write_cache(\%parsed_torrents, 'parsed');
    return \%parsed_torrents;
}

# Leaving commented match_by_date as-is for now per instructions.
# TODO: Review whether to restore or delete.

1;
