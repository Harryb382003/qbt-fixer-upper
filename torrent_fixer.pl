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
  normalize_filename
  report_collision_groups
);
use ZombieManager;
use Utils qw(
            normalize_to_arrayref
            sprinkle
            );
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
           "dev-mode"       => \$opts{dev_mode},
           "chunk=i"        => \$opts{chunk},
           "invert-colors"  => \$opts{invert_colors},
           "log-dir=s"      => \$opts{log_dir},
           "max-cache=i"    => \$opts{max_cache},
           "normalize|n=s"  => \$opts{normalize},
           "tor-dir"        => \$opts{torrent_dir},
           "verbose|v+"     => \$opts{verbose_level},
           "scan-zombies|z" => \$opts{scan_zombies},
           "wiggle=i"       => \$opts{wiggle},
           "help|h"         => sub { usage(); exit(0); },
           )
    or usage();

# --- Set Defaults ---
$opts{os}            = Utils::test_OS();
$opts{dark_mode}     = Utils::detect_dark_mode($opts{os});
$opts{chunk}       ||= $cfg->{chunk}          || 5;        # default to chunks of 5
$opts{max_cache}   ||= $cfg->{max_cache}      // 2;    # default to 2 cache files of each type
$opts{normalize}   ||= $cfg->{normalize}      || 0;
$opts{wiggle}      ||= $cfg->{wiggle}         || 10;         # default to 10 minutes if not provided
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "/";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];

make_path($opts{log_dir}) unless -d $opts{log_dir};

# --- Normalize options ---
if (exists $opts{normalize}) {
    my $mode = $opts{normalize};

    $opts{normalize_mode} = 0;   # default: off
    $opts{dry_run}        = 0;   # default: no dry-run

    if ($mode =~ /^([ac])([d]?)$/i) {
        $opts{normalize_mode} = $1;
        $opts{dry_run}        = 1 if $2;
    }
    elsif ($mode eq '0') {
        $opts{normalize_mode} = 0;        # explicit off
        Logger::info("[MAIN] Normalization disabled (--normalize=0)");
    }
    else {
        die "[MAIN] Invalid --normalize value: $mode\n"
          . "Use: 0 (off), a (all), c (colliders), ad/cd (dry-run)";
    }
}

# --- Setup ---
Logger::init(\%opts);
Logger::info("Logger initialized");

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

$opts{export_dir}     = normalize_to_arrayref($prefs->{export_dir});
$opts{export_dir_fin} = normalize_to_arrayref($prefs->{export_dir_fin});

say "export_dir:     ", join(", ", @{ $opts{export_dir}     || [] });
say "export_dir_fin: ", join(", ", @{ $opts{export_dir_fin} || [] });



my $qbt_loaded_tor = $qb->get_torrents_infohash();


# --- TorrentParser ---
my $tp = TorrentParser->new(
      {all_torrents => \@all_t,    # fresh master list
       opts         => \%opts,     # pass opts as hashref
      });

my $l_parsed = $tp->extract_metadata;

# report_top_dupes($l_parsed, 5);   # show top 5 per bucket
report_collision_groups($l_parsed->{collisions});

# --- Normalization ---
if ($opts{normalize_mode}) {
    Logger::info("\n[MAIN] Starting normalization pass...");
    normalize_filename($l_parsed, \%opts);
}

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
