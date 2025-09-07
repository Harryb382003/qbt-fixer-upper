#!/usr/bin/env perl

use common::sense;
use Data::Dumper;
use Cwd qw(getcwd);
use POSIX qw(strftime);
use JSON;
use Getopt::Long qw(:config bundling);
use File::Basename qw(dirname basename);
use File::Path;
use File::Slurp;
use File::Spec;
use String::ShellQuote;

use lib 'lib';
use QBittorrent;
use TorrentParser qw(
              locate_torrents
              extract_metadata
              process_all_infohashes
              normalize_filename
              report_collision_groups
              );
use ZombieManager;
use Utils qw(
            locate_items
            ensure_temp_ignore_dir
            normalize_to_arrayref
            );
use Logger;
#use DevTools;

sub usage {
  print <<"EOF";
sage: $0 [options]
Options:
  --repair              Adds torrents with a verified payload only
  --normalize           normalize torrent name to *.torrent's authoritative name
  --dev-mode            extra reporting
  --chunk n             process in chunks of n
  --dump-lines=i        First 5 lines of the Dumper output, unless --full-dump is passed
  --invert-colors       Invert day/night mode
  --verbose, -v         Increase verbosity
  --log-dir=<path>      Output path for logs
  --scan-zombies, -z    search for zombie torrents in qbt
  --wiggle=i            Time wiggle in minutes for date matching
  --help, -h            how help
EOF
  exit(1);
}

# --- Load Configuration ---
my $cfg_file = "config.json";
my $cfg      = -e $cfg_file ? decode_json(read_file($cfg_file)) : {};

# --- Options ---
my %opts;
GetOptions(
           "repair"         => \$opts{repair},
           "dev-mode"       => \$opts{dev_mode},
           "chunk=i"        => \$opts{chunk},
           "invert-colors"  => \$opts{invert_colors},
           "log-dir=s"      => \$opts{log_dir},
           "max-cache=i"    => \$opts{max_cache},
           "normalize|n=s"  => \$opts{normalize},
           "tor-dir"        => \$opts{torrent_dir},
           "verbose|v+"     => \$opts{verbose},
           "scan-zombies|z" => \$opts{scan_zombies},
           "wiggle=i"       => \$opts{wiggle},
           "help|h"         => sub { usage(); exit(0); },
           )
    or usage();

# --- Get Defaults ---
$opts{os}            = Utils::test_OS();
$opts{dark_mode}     = Utils::detect_dark_mode($opts{os});
$opts{chunk}       ||= $cfg->{chunk}          || 5;        # default to chunks of 5
$opts{max_cache}   ||= $cfg->{max_cache}      // 2;    # default to 2 cache files of each type
$opts{normalize}   ||= $cfg->{normalize}      || 0;
$opts{wiggle}      ||= $cfg->{wiggle}         || 10;# default to 10 minutes if not provided
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "/";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];
# GetOptions('verbose|v+' => \$opts{verbose}, ...);
$opts{verbose}     //= 0;

make_path($opts{log_dir}) unless -d $opts{log_dir};

my $temp_ignore = File::Spec->catdir(getcwd(), 'temp_ignore');
make_path($temp_ignore) unless -d $temp_ignore;
$opts{temp_ignore_dir} = $temp_ignore;

# --- Normalize options ---
if (exists $opts{normalize}) {
    my $mode = $opts{normalize};

    $opts{normalize_mode} = 0;   # default: off

    if ($mode =~ /^([ac])([d]?)$/i) {
        $opts{normalize_mode} = $1;
    }
    elsif ($mode eq '0') {
        $opts{normalize_mode} = 0;        # explicit off
        Logger::info("Normalization disabled (--normalize = 0)");
    }
    else {
        die "Invalid --normalize value: $mode\n"
          . "se: 0 (off), a (all), c (colliders), ad/cd (dry-run)";
    }
}

# --- Setup ---# after parsing CLI into %opts
Logger::info("[MAIN] verbose=$opts{verbose}");
Logger::init(\%opts);
Logger::debug("[MAIN] debug is ON (probe)");   # should appear if debug works
Logger::info("Logger initialized");

# --- Main logic placeholder ---
Logger::info("Starting processing...");

# The rest of the torrent fixing logic follows here.


# --- Locate Torrents ---
# This is always a fresh start.
# aintaining a cache here would have a huge disk footprint.
my @all_t = locate_torrents(\%opts);

Logger::info("FileLocator complete, passing to TorrentParser");
Logger::summary("Torrent files located\t\t" . scalar(@all_t) );
ensure_temp_ignore_dir(\%opts);   # creates ./temp_ignore and flags it as ignore

# --- Load QBittorrent ---
# This is always a fresh start.
# aintaining a cache here would keep us from having live stats..
my $qb             = QBittorrent->new(\%opts);
my $prefs = $qb->get_preferences;

$opts{export_dir}     = normalize_to_arrayref($prefs->{export_dir});
$opts{export_dir_fin} = normalize_to_arrayref($prefs->{export_dir_fin});

if (ref $opts{export_dir_fin} eq 'ARRAY') {
    push @{ $opts{export_dir_fin} }, $opts{temp_ignore_dir};
} elsif ($opts{export_dir_fin}) {
    $opts{export_dir_fin} = [ $opts{export_dir_fin}, $opts{temp_ignore_dir} ];
} else {
    $opts{export_dir_fin} = [ $opts{temp_ignore_dir} ];
}

say "export_dir:     ", join(", ", @{ $opts{export_dir}     || [] });
say "export_dir_fin: ", join(", ", @{ $opts{export_dir_fin} || [] });



my $qbt_loaded_tor = $qb->get_torrents_infohash;

# --- TorrentParser ---
my $tp = TorrentParser->new(
      {all_torrents => \@all_t,    # fresh master list
       opts         => \%opts,     # pass opts as hashref
      });

my $l_parsed = $tp->extract_metadata($qbt_loaded_tor);

# report_top_dupes($l_parsed, 5);   # show top 5 per bucket
report_collision_groups($l_parsed->{collisions});

# --- Normalization ---
if ($opts{normalize_mode}) {
    Logger::info("\nStarting normalization pass...");
    normalize_filename($l_parsed, \%opts);
}

# --- QBT add queue ---

# Authoritative working queue: $l_parsed->{pending_add} (arrayref).
# Use this for your destructive chunk() loop.
# It keeps main lean and blazing simple.









Logger::info("\nStarting to add torrents...");
my @pending = $qb->import_from_parsed($l_parsed, \%opts);





process_all_infohashes($l_parsed, \%opts);

#
# # --- Zombie Detection ---
# my $zm = Zombieanager->new(
#     qb      => $qb,
#     zombies => $caches{zombies},
#     opts    => \%opts,
# );
# sprinkle('zm', $zm);

# dd other managers here...

Logger::flush_summary();
