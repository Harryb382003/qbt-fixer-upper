#!/usr/bin/env perl

use common::sense;
use Getopt::Long qw(:config bundling);
use File::Path   qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use JSON;
use File::Slurp;
use Data::Dumper;
use String::ShellQuote qw(shell_quote);

use lib 'lib';
use FileLocator;
use QBittorrent;
use TorrentParser qw(extract_metadata);
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
$opts{wiggle}      ||= 10;    # default to 10 minutes if not provided
$opts{dedupe_dir}  ||= $cfg->{dedupe_dir}     || "duplicates";
$opts{log_dir}     ||= $cfg->{log_dir}        || "logs";
$opts{torrent_dir} ||= $cfg->{torrent_dir}    || "torrents";
$opts{excluded}    ||= $cfg->{excluded_paths} || [];
make_path($opts{log_dir}) unless -d $opts{log_dir};


Utils::ensure_directories(\%opts);
my $color_schema = Utils::load_color_schema($opts{dark_mode});


# After GetOptions and before doing any cache loads
if ($opts{'dev-mode'}) {
    say "\e[33;1m[DEV] Developer mode active — results may be truncated for speed!\e[0m";
}


Logger::init(\%opts);


# --- Locate Torrents ---
my @all_t = FileLocator::locate_l_torrents(\%opts);


# --- Load QBittorrent ---
my $qb             = QBittorrent->new(%opts);
my $qbt_loaded_tor = $qb->get_torrents_infohash();


# --- Extract Metadata (try cache first) ---
my ($parsed_torrents,   $parsed_file)   = Utils::load_cache('parsed');
my ($dupes_by_infohash, $dupes_file)    = Utils::load_cache('dupes');
my ($problem_torrents,  $problems_file) = Utils::load_cache('problems');

unless ($parsed_torrents && $dupes_by_infohash && $problem_torrents)
{
  Logger::warn("[WARN] Missing one or more caches — computing from scratch");
  my $parser = TorrentParser->new(%opts);
  $parsed_torrents = $parser->extract_metadata(\@all_t, \%opts);
  Utils::write_cache($parsed_torrents,   'parsed');
  Utils::write_cache($dupes_by_infohash, 'dupes');
  Utils::write_cache($problem_torrents,  'problems');
}

my @torrents_extracted_successfully = values %$parsed_torrents;


# --- Zombie Detection ---
my $zm = ZombieManager->new(qb => $qb);
my $result;
my $zombies;
my $zombie_file;


# Try to load zombies cache
($zombies, $zombie_file) = Utils::load_cache('zombies');


# Ensure zombies is always a hashref, warn if empty
$zm->{zombies} = ($zombies && %$zombies)
    ? $zombies
    : do {
        Logger::warn("[WARN] No zombies loaded, using empty hash");
        {};
    };

if ($zombies && %$zombies) {
    Logger::info("[INFO] zombies cache loaded from $zombie_file (" . scalar(keys %$zombies) . " entries)");
    if ($opts{dev_mode}) {
        require DevTools;
        Logger::warn("[DEV] Chunking zombies list to first 5 entries for faster dev runs");
        $zombies = DevTools::chunk($zombies, 5);
    }
}
elsif ($opts{scan_zombies}) {
    Logger::warn("[WARN] No zombie cache found — performing full zombie scan...");
    $zombies = $zm->scan_full();
    Utils::write_cache($zombies, 'zombies') if $zombies && %$zombies;
    if ($opts{dev_mode}) {
        require DevTools;
        Logger::warn("[DEV] Chunking zombies list to first 5 entries for faster dev runs");
        $zombies = DevTools::chunk($zombies, 5);
    }
}
else {
    Logger::warn("[WARN] No zombie cache found and --scan-zombies not specified — skipping zombie matching.");
    # Skip matching entirely if no cache and no scan requested
    goto ZOMBIE_DONE;
}


# Attempt to gather some filesystem metadata on zombies
my $mdls_results = Utils::get_mdls($parsed_torrents);
die "[MDLS] Full metadata pull complete — exiting early.\n";

# At this point, $zombies should be populated either from cache or scan
#$result = $zm->match_by_date(\@torrents_extracted_successfully, $opts{wiggle});


say "148";




if ($result->{match_count} && $result->{match_count} > 0) {

    Logger::info("[MATCHES] Found $result->{match_count} zombies with matching torrent files");

}

if ($result->{no_added_on_count} && $result->{no_added_on_count} > 0) {

    Logger::info("[NO DATE] $result->{no_added_on_count} zombies missing added_on, sent to next filter");

}

if ($result->{no_save_path_count} && $result->{no_save_path_count} > 0) {

    Logger::info("[NO SAVE PATH] $result->{no_save_path_count} zombies missing save_path, sent to next filter");

}

Utils::write_cache($result->{matches}, 'matches')
    if $result->{matches} && @{$result->{matches}};

ZOMBIE_DONE:

# --- Dev Mode Summary ---
if ($opts{dev_mode})
{
  DevTools::print_cache_summary(
                                {parsed   => 'parsed',
                                 dupes    => 'dupes',
                                 problems => 'problems',
                                 zombies  => 'zombies',
                                 matches  => 'matches'});
}

# --- mdfind Skipped Query Report ---
if ($Utils::mdfind_skipped_invalid > 0 || $Utils::mdfind_skipped_unsafe > 0)
{
  Logger::warn("[WARN] Skipped mdfind queries due to invalid or unsafe input:");
  if ($Utils::mdfind_skipped_invalid > 0) {
      Logger::warn(
              "  Invalid/empty queries skipped: $Utils::mdfind_skipped_invalid");
  }
  if ($Utils::mdfind_skipped_unsafe > 0) {
      Logger::warn("  Unsafe queries skipped: $Utils::mdfind_skipped_unsafe");
  }

  # Optional: dump the actual queries for debugging
  if (@Utils::mdfind_invalid_queries)
  {
    Logger::info("[INFO] Skipped queries list:");
    foreach my $bad (@Utils::mdfind_invalid_queries)
    {
      Logger::info("    $bad");
    }
  }
}
say "\n--- Summary ---";

my $zombie_total =
    $zombies && ref $zombies eq 'HASH' ? scalar keys %$zombies : 0;
my $matched_total = $result
    && ref $result->{matches} eq 'ARRAY' ? scalar @{$result->{matches}} : 0;

Logger::info("[SUMMARY] Deduplication complete 🚧");
Logger::info("[SUMMARY] Total discovered on disk        \t" . scalar(@all_t));
Logger::info("[SUMMARY] Torrents loaded in qBittorrent     \t"
             . scalar(keys %{$qbt_loaded_tor}));
Logger::info("[SUMMARY] Zombie torrents in qBittorrent: \t$zombie_total");
Logger::info("[SUMMARY] Torrents extracted successfully: \t" . scalar
             keys %$parsed_torrents);
Logger::info("[SUMMARY] Duplicate torrents found: \t\t" . scalar
             keys %$dupes_by_infohash);
Logger::info(
          "[SUMMARY] Failed to parse: \t\t\t" . scalar keys %$problem_torrents);
Logger::info("[SUMMARY] Zombies matched torrent files: \t$matched_total");
Logger::info("[SUMMARY] Zombies matched torrent files:  $result->{matches_count}");
Logger::info("[SUMMARY] Zombies escaped date filter:    $result->{escaped_count}");

# Positive match highlight
if ($matched_total > 0) {
    Logger::info(
         "[MATCH] Successfully matched $matched_total zombies to torrent files");
}
