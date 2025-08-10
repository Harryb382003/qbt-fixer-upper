#!/usr/bin/env perl

use common::sense;
use Getopt::Long qw(:config bundling);
use File::Path   qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use JSON;
use File::Slurp;

use lib 'lib';
use FileLocator;
use QBittorrent;
use TorrentParser;
use ZombieManager;

# use Logger;
# use DedupeEngine;
# use Chunk qw(apply_chunking);
# use Sieve qw(filter_by_export_dirs filter_loaded_infohashes);
# use DevTools qw(
#     dev_compare_qbt_vs_exports_detailed
#     verify_reference_infohashes
# );
# use Utils qw(start_timer stop_timer extract_used_cli_opts);

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

  --help, -h            Show help
EOF

  #  --allow-fallback      Allow File::Find (slow resource hog)
  #   --backup, -b          Create backups
  #   --report-orphans      Report orphan torrents
  #   --clean-orphans       Delete orphan torrents
  #   --interactive, -i     Prompt interactively
  #   --deep-verify         Hash-based verification
  #   --dedupe-dir=<path>   Output path for duplicates
  #   --exists, -e          Act only on existing files
  #   --load                Load .torrent files into qBittorrent
  #  --H                   Disable human-readable sizes
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
           "help|h"         => sub { usage(); exit(0); })
    or usage();

#   "allow-fallback"   => \$opts{allow_fallback},
#   "chunk=i"          => \$opts{chunk},
#   "backup|b"         => \$opts{backup},
#   "report-orphans"   => \$opts{report_orphans},
#   "clean-orphans"    => \$opts{clean_orphans},
#   "interactive|i"    => \$opts{interactive},
#   "deep-verify"      => \$opts{deep_verify},
#   "dedupe-dir=s"     => \$opts{dedupe_dir},
#   "exists|e"         => \$opts{only_existing},
#   "load"             => \$opts{load},
#  "H"                => \$opts{human_bytes},

# --- Set Defaults ---
$opts{os}        = Utils::test_OS();
$opts{dark_mode} = Utils::detect_dark_mode($opts{os});
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "torrents";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];
make_path($opts{log_dir}) unless -d $opts{log_dir};

Logger::init(\%opts);
my $used_opts = Utils::extract_used_cli_opts(\%opts);
Logger::log_used_opts($used_opts);

my @all_t = FileLocator::locate_l_torrents(\%opts);

my $qb             = QBittorrent->new(%opts);
my $q_prefs        = $qb->get_preferences();
my $qbt_loaded_tor = $qb->get_torrents_infohash();

my $q_zombie_count = "use --scan-zombies for value. Can be slow";

say "\n--- Extract Metadata ---";

# this will also cull duplicate torrents via $infohash
# actual deletion of the files will happen elsewhere
my ($parsed_torrents, $dupes_by_infohash, $problem_torrents) =
    TorrentParser::extract_metadata(\@all_t, \%opts);

# --- Zombie Detection ---
my $zm = ZombieManager->new(qb => $qb);

my $zombies;

if ($opts{scan_zombies})
{
  Logger::info("[INFO] Performing full zombie scan...");
  $zombies = ZombieManager::scan_full($qb);
  ZombieManager::write_cache($zombies) if $zombies;
}
else
{
  $zombies = ZombieManager::load_cache();
  if ($zombies)
  {
    Logger::info("[INFO] Using zombies from existing cache");
  }
  else
  {
    Logger::warn(
           "[WARN] No zombie cache available — skipping zombie classification");
  }
}

# Step 2: Classify only if we actually have zombies
my $heal_candidates = {};
if ($zombies)
{
  $heal_candidates =
      ZombieManager::classify_zombies_by_infohash_name($zombies,
                                                       $parsed_torrents);
}

# Export heal candidates JSON
if (keys %{$zm->{heal_candidates}})
{
  $zm->write_heal_candidates();
}

# Optional: export disposal candidates
if (keys %{$zm->{disposal_candidates}})
{
  $zm->write_disposal_candidates();
}

say "\n--- Summary ---";

Logger::info("[SUMMARY] Deduplication complete 🚧");
Logger::info("[SUMMARY] Total discovered on disk        \t" . scalar(@all_t));
Logger::info("[SUMMARY] Torrents loaded in qBittorrent     \t"
             . scalar(keys %{$qbt_loaded_tor}));
Logger::info("[SUMMARY] Zombie torrents in qBittorrent: \t" . $q_zombie_count);
Logger::info("[SUMMARY] Torrents extracted successfully: \t" . scalar
             keys %$parsed_torrents);
Logger::info("[SUMMARY] Duplicate torrents found: \t\t" . scalar
             keys %$dupes_by_infohash);
Logger::info(
          "[SUMMARY] Failed to parse: \t\t\t" . scalar keys %$problem_torrents);

say "\n--- Export dedup report ---";

my $ts = strftime("%Y-%m-%dT%H:%M:%SZ", gmtime());
my $report = {report_type    => 'torrent_dedupe',
              schema_version => 1,
              timestamp      => $ts,
              summary        => {
                          discovered    => scalar(@all_t),
                          parsed_unique => scalar keys %$parsed_torrents,
                          duplicates    => scalar keys %$dupes_by_infohash,
                          failed_parse  => scalar keys %$problem_torrents,
                         },
              dupes => [values %$dupes_by_infohash],};

my $json_obj = JSON->new->utf8->pretty;

my $json_str = $json_obj->encode($report);

write_file("dedupe_report.json", JSON->new->utf8->pretty->encode($report));
Logger::info("[EXPORT] dedupe_report.json written");
