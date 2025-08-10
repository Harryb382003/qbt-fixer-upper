package TorrentParser;

use common::sense;
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


our @EXPORT_OK = qw(extract_metadata);


my $CACHE_FILE = "cache/hash_cache.json";
my $problem_log_file = "logs/problem_torrents.json";

my %hash_cache;

if (-e $CACHE_FILE) {
    my $json = read_file($CACHE_FILE);
    %hash_cache = %{ decode_json($json) };
}



sub extract_metadata {
	Logger::debug("#	extract_metadata");
    my ($file_list_ref, $opts) = @_;
    Utils::start_timer("extract_metadata");

    my %parsed;
    my %dupes_by_infohash;
    my %problem_torrents;
    my %skipped;

    foreach my $file_path (@$file_list_ref) {
        next unless -e $file_path;

        my $torrent;
        eval { $torrent = bdecode_file($file_path); };

        if ($@ or !$torrent) {
            my ($short_error) = $@ =~ /^(.*?)(?: at |$)/s;
            my $basename = File::Basename::basename($file_path);
            Logger::warn("Failed to parse $basename: $short_error");
            $problem_torrents{$file_path} = { error => $short_error };
            next;
        }

        my $info = $torrent->{info};
        unless ($info) {
            $skipped{$file_path} = { reason => 'Missing info dict' };
            next;
        }

        delete $info->{pieces} if exists $info->{pieces};
        my $infohash = sha1_hex(bencode($info));

        my $record = {
            name        => $info->{name} // '(unnamed)',
            files       => $info->{files}
                              ? [ map { $_->{path} } @{ $info->{files} } ]
                              : [ $info->{name} ],
            total_size  => $info->{files}
                              ? sum(map { $_->{length} || 0 } @{ $info->{files} })
                              : $info->{length} || 0,
            raw         => $torrent,
            source_path => $file_path,
        };

        if (exists $parsed{$infohash}) {
            push @{ $dupes_by_infohash{$infohash} }, $record;
        } else {
            $parsed{$infohash} = $record;
        }
    }

    my $total_input = scalar(@$file_list_ref);
    my $count_parsed = scalar(keys %parsed);
    my $count_dupes  = sum(map { scalar(@$_) } values %dupes_by_infohash);
    my $count_failed = scalar(keys %problem_torrents);
    my $count_skipped = scalar(keys %skipped);
    my @stats = ($total_input, $count_parsed, $count_dupes, $count_failed, $count_skipped );

    Logger::debug(" Total in: $total_input");
    Logger::debug(" Parsed unique: $count_parsed");
    Logger::debug(" Dupes: $count_dupes");
    Logger::debug(" Failed: $count_failed");
    Logger::debug(" Skipped: $count_skipped");
    Logger::debug(" Sum check: " . (
            $count_parsed +
            $count_dupes +
            $count_failed +
            $count_skipped)
            );

    Utils::stop_timer("extract_metadata");
    return (\%parsed, \%dupes_by_infohash, \%problem_torrents, \%skipped, \@stats);
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
