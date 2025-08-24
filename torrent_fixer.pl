#!/usr/bin/env perl

use common::sense;
use Data::Dumper;
use POSIX qw(strftime);
use JSON;
use Getopt::Long qw(:config bundling);
use File::Basename qw(dirname basename);
use File::Path;
use File::Slurp;
use File::Spec;
use String::ShellQuote;

use lib 'lib';
use FileLocator;
use QBittorrent;
use TorrentParser qw(
  extract_metadata
  process_all_infohashes
);
use ZombieManager;
use Utils qw(sprinkle);
use Logger;
use DevTools;

sub usage {
  print <<"EOF";
Usage: $0 [options]
Options:
  --normalize           normalize torrent name to *.torrent's authoritative name
  --dev-mode            is effectively just a safety wrapper around any code that would change something in qBittorrent
or on disk.
  --chunk n             process in chunks of n
  --dump-lines=i        First 5 lines of the Dumper output, unless --full-dump is passed
  --full-dump           unleash the kraken onto your terminal
  --
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

# --- Options ---
my %opts;
GetOptions(
           "normalize|n"    => \$opts{normalize},
           "max-cache"      => \$opts{max_cache},
           "dev-mode"       => \$opts{dev_mode},
           "dry-run|d"      => \$opts{dry_run},
           "chunk=i"        => \$opts{chunk},
           "dump-lines=i"   => \$opts{dump_lines},
           "full-dump"      => \$opts{full_dump},
           "invert-colors"  => \$opts{invert_colors},
           "log-dir=s"      => \$opts{log_dir},
           "tor-dir"        => \$opts{torrent_dir},
           "verbose|v+"     => \$opts{verbose_level},
           "scan-zombies|z" => \$opts{scan_zombies},
           "wiggle=i"       => \$opts{wiggle},
           "help|h"         => sub { usage(); exit(0); })
    or usage();

# --- Set Defaults ---
$opts{os}        = Utils::test_OS();
$opts{dark_mode} = Utils::detect_dark_mode($opts{os});
$opts{chunk}     ||= $cfg->{chunk} || 5;    # default to chunks of 5
$opts{max_cache} ||= $cfg->{max_cache}
    // 2;    # default to 2 cache files of each type
$opts{wiggle} ||= $cfg->{wiggle} || 10;  # default to 10 minutes if not provided
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "/";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];

make_path($opts{log_dir}) unless -d $opts{log_dir};

# --- Setup ---
$opts{wiggle} //= 10;
Logger::init(\%opts);
Logger::info("Logger initialized");

# --- Cache Orchestration ---
# Preload all known caches en masse to pass into managers
# This ensures single load + clear flow, but still allows modules
# to lazy-load if called outside main.

# --- This was an exercise in futility
# --- Leaving code in place a reminder to stay out of the weeds
# ---   or off the weed as the case may be!

# # # # Logger::info("Loading caches...");

# # # # my %caches;
# # # # foreach my $type (qw(parsed dupes zombies problems)) {
# # # #     my ($cache, $file, $err) = Utils::load_cache($type);
# # # #
# # # #     if ($cache) {
# # # #         my $count = (ref($cache) eq 'HASH') ? scalar(keys %$cache) : scalar(@$cache);
# # # #         Logger::info("[CACHE] Loaded '$type' cache ($count entries) from $file");
# # # #     }
# # # #     else {
# # # #         Logger::warn("[CACHE] No '$type' cache available ($err)") if $err;
# # # #     }
# # # #
# # # #     $caches{$type} = $cache; # store undef if it failed, keeps shape consistent
# # # # }
# # # #
# # # # Logger::info("Cache preload complete — handing off to managers");

# --- Main logic placeholder ---
Logger::info("[MAIN] Starting processing...");

# The rest of the torrent fixing logic follows here.


# --- Locate Torrents ---
# This is always a fresh start.
# Maintaining a cache here would have a huge disk footprint.
my @all_t = FileLocator::locate_l_torrents(\%opts);
Logger::info("[MAIN] FileLocator complete, passing to TorrentParser");
Logger::summary("[TORRENTS] Torrent files located\t\t" . scalar(@all_t) );


# --- Load QBittorrent ---
# This is always a fresh start.
# Maintaining a cache here would keep us from having live stats..
my $qb             = QBittorrent->new(\%opts);
my $prefs = $qb->get_preferences;

# Force into arrayrefs so _assign_bucket is consistent
$opts{export_dir} = ref $prefs->{export_dir} eq 'ARRAY'
                      ? $prefs->{export_dir}
                      : $prefs->{export_dir}
                      ? [ $prefs->{export_dir} ]
                      : [];

$opts{export_dir_fin} = ref $prefs->{export_dir_fin}  eq 'ARRAY'
                          ? $prefs->{export_dir_fin}
                          : $prefs->{export_dir_fin}
                          ? [ $prefs->{export_dir_fin} ]
                          : [];

my $qbt_loaded_tor = $qb->get_torrents_infohash();


# --- TorrentParser ---
my $tp = TorrentParser->new(
      {all_torrents => \@all_t,    # fresh master list
       opts         => \%opts,     # pass opts as hashref
      });

my $l_parsed = $tp->extract_metadata;

process_all_infohashes($l_parsed, \%opts);

#
# # --- Zombie Detection ---
# my $zm = ZombieManager->new(
#     qb      => $qb,
#     zombies => $caches{zombies},
#     opts    => \%opts,
# );
# sprinkle('zm', $zm);

# Add other managers here...

Logger::flush_summary();
