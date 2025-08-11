#!/usr/bin/env perl

use common::sense;
use Getopt::Long qw(:config bundling);
use File::Path   qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use JSON;
use File::Slurp;
use Data::Dumper;

use lib 'lib';
use FileLocator;
use QBittorrent;
use TorrentParser;
use ZombieManager;
use Utils;
use Logger;
use DevTools;

# --- Usage ---
sub usage {
  print <<"EOF";
Usage: $0 [options]
Options:
  --dev-mode            Mock behavior for testing
  --dry-run, -d         is effectively just a safety wrapper around any code that would change something in qBittorrent
                        or on disk.
  --dump-lines=i        First 5 lines of the Dumper output, unless --full-dump is passed
  --full-dump           unleash the kraken onto your terminal
  --invert-colors       Invert day/night mode
  --verbose, -v         Increase verbosity
  --log-dir=<path>      Output path for logs
  --scan-zombies, -z    search for zombie torrents in qbt
  --wiggle=i            Time wiggle in minutes for date matching
  --help, -h            Show help
EOF
  exit(1);
}

# --- Load Configuration ---
my $cfg_file = "config.json";
my $cfg      = -e $cfg_file ? decode_json(read_file($cfg_file)) : {};

# --- Parse Options ---
my %opts;
GetOptions("dev-mode"       => \$opts{dev_mode},
           "dry-run|d"      => \$opts{dry_run},
           "dump-lines=i"   => \$opts{dump_lines},
           "full-dump"      => \$opts{full_dump},
           "invert-colors"  => \$opts{invert_colors},
           "log-dir=s"      => \$opts{log_dir},
           "verbose|v+"     => \$opts{verbose_level},
           "scan-zombies|z" => \$opts{scan_zombies},
           "wiggle=i"       => \$opts{wiggle},
           "help|h"         => sub { usage(); exit(0); })
    or usage();

# --- Set Defaults ---
$opts{os}        = Utils::test_OS();
$opts{dark_mode} = Utils::detect_dark_mode($opts{os});
$opts{wiggle}      ||= 10;   # default to 10 minutes if not provided
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "torrents";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];
make_path($opts{log_dir}) unless -d $opts{log_dir};
my $color_schema = Utils::load_color_schema($opts{dark_mode});

Logger::init(\%opts);

# --- Locate Torrents ---
my @all_t = FileLocator::locate_l_torrents(\%opts);

# --- Load QBittorrent ---
my $qb  = QBittorrent->new(%opts);
my $qbt_loaded_tor = $qb->get_torrents_infohash();

# --- Extract Metadata (try cache first) ---
my ($parsed_torrents, $parsed_file) = Utils::load_cache('parsed');
my ($dupes_by_infohash, $dupes_file) = Utils::load_cache('dupes');
my ($problem_torrents, $problems_file) = Utils::load_cache('problems');

unless ($parsed_torrents && $dupes_by_infohash && $problem_torrents) {
    Logger::warn("[WARN] Missing one or more caches — computing from scratch");
    ($parsed_torrents, $dupes_by_infohash, $problem_torrents) =
        TorrentParser::extract_metadata(\@all_t, \%opts);
    Utils::write_cache($parsed_torrents, 'parsed');
    Utils::write_cache($dupes_by_infohash, 'dupes');
    Utils::write_cache($problem_torrents, 'problems');
}

my @torrents_extracted_successfully = values %$parsed_torrents;

# --- Zombie Detection ---
my $zm = ZombieManager->new(qb => $qb);
my ($zombies, $zombie_file) = Utils::load_cache('zombies');

if ($opts{scan_zombies} || !$zombies) {
    Logger::info("[INFO] Performing full zombie scan...");
    $zombies = $zm->scan_full();
    Utils::write_cache($zombies, 'zombies');
}

# --- Match by Date ---
my $result = $zm->match_by_date(\@torrents_extracted_successfully, $opts{wiggle});
Logger::info("[MATCHES] Found " . scalar(@{$result->{matches}}) . " zombies with matching torrent files");
Logger::info("[NO DATE] " . scalar(@{$result->{no_added_on}}) . " zombies missing added_on, sent to next filter");
Utils::write_cache($result->{matches}, 'matches');

# --- Dev Mode Summary ---
if ($opts{dev_mode}) {
    DevTools::print_cache_summary({
        parsed  => 'parsed',
        dupes   => 'dupes',
        problems=> 'problems',
        zombies => 'zombies',
        matches => 'matches'
    });
}

Logger::info("[SUMMARY] Deduplication complete 🚧");
