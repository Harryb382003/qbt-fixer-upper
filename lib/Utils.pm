package Utils;

use common::sense;
use File::Path qw(make_path);
use File::Spec;
use File::Basename qw(basename);
use POSIX qw(strftime);
use File::Slurp;
use String::ShellQuote qw(shell_quote);
use Time::HiRes qw(gettimeofday tv_interval);
use JSON;
use Exporter 'import';

use lib 'lib';
use Logger;


our @EXPORT_OK = qw(
                start_timer
                stop_timer
                _find_latest_cache_file
                );

sub ensure_directories {
    my ($opts) = @_;
    my @dirs = ('cache', $opts->{log_dir}, $opts->{dedupe_dir});

    for my $dir (@dirs) {
        next unless defined $dir && $dir ne '';

        if (-d $dir) {
            unless (-w $dir) {
                my $msg = "[FATAL] Directory '$dir' exists but is not writable!";
                if ($dir eq 'cache') {
                    die "$msg Cache must be writable.\n";
                }
                warn "$msg\n";
            }
            next;
        }

        make_path($dir) or do {
            my $msg = "[FATAL] Could not create directory '$dir'";
            if ($dir eq 'cache') {
                die "$msg Cache must exist.\n";
            }
            warn "$msg\n";
            next;
        };

        print "[DEV] Created directory '$dir'\n" if $opts->{dev_mode};
    }
}

sub write_cache {
    my ($data, $type, $verbosity) = @_;
    die "[FATAL] write_cache() missing required 'type' argument\n"
        unless defined $type;

    # Bail if data is empty (undef, empty array, or empty hash)
    if (
        !defined $data ||
        (ref $data eq 'HASH'  && !%$data) ||
        (ref $data eq 'ARRAY' && !@$data)
    ) {
        Logger::warn("[WARN] Skipping write for $type cache — no entries.");
        return;
    }

    # Ensure cache directory exists
    my $cache_dir = "cache";
    File::Path::make_path($cache_dir) unless -d $cache_dir;

    # Timestamped file name
    my $timestamp = POSIX::strftime("%y.%m.%d-%H.%M", localtime);
    my $cache_file = File::Spec->catfile($cache_dir, "zombies_cache_${type}_${timestamp}.json");

    # Latest symlink-like file
    my $latest_file = File::Spec->catfile($cache_dir, "zombies_cache_${type}_latest.json");

    # Write the data
    my $json = JSON->new->utf8->pretty->canonical;
    eval {
        File::Slurp::write_file($cache_file, $json->encode($data));
        File::Slurp::write_file($latest_file, $json->encode($data));
        Logger::info("[INFO] $type cache written to $cache_file (" . (
            ref($data) eq 'HASH' ? scalar(keys %$data) : scalar(@$data)
        ) . " entries)");
    };
    if ($@) {
        Logger::error("[ERROR] Failed to write $type cache: $@");
        return;
    }

    return $cache_file;
}

sub load_cache {
    my ($type) = @_;
    unless ($type && $type =~ /^[a-z0-9_]+$/i) {
    Logger::warn("[WARN] load_cache() called without valid type — skipping load");
    return;
}

    my $dir = "cache";
    my $latest = File::Spec->catfile($dir, "zombies_cache_${type}_latest.json");

    unless (-e $latest) {
        Logger::warn("[WARN] No cache file found for type '$type'");
        return;
    }

    my $data = decode_json(read_file($latest));
    Logger::info("[INFO] $type cache loaded from $latest (" . _count_entries($data) . " entries)");
    return ($data, $latest);
}

sub _count_entries {
    my ($data) = @_;
    return 0 unless $data;
    return ref($data) eq 'HASH' ? scalar keys %$data
         : ref($data) eq 'ARRAY' ? scalar @$data
         : 1;
}

sub _cleanup_cache {
    my ($dir, $type, $keep) = @_;
    my @files = sort { -M $a <=> -M $b }
                grep { /zombies_cache_${type}_\d{2}\.\d{2}\.\d{2}-\d{4}\.json$/ }
                glob("$dir/*.json");

    if (@files > $keep) {
        my @old = @files[$keep .. $#files];
        unlink @old;
        Logger::info("[INFO] Cleaned up " . scalar(@old) . " old '$type' cache file(s)");
    }
}

# Internal helper: count items in data
sub _count_entries {
    my ($data) = @_;
    return (ref $data eq 'HASH') ? scalar keys %$data
         : (ref $data eq 'ARRAY') ? scalar @$data
         : 1;
}

sub test_OS {
    my $osname = $^O;  # Built-in Perl variable for OS name

    if ($osname =~ /darwin/i) {
        return 'macos';
    }
    elsif ($osname =~ /linux/i) {
        return 'linux';
    }
    elsif ($osname =~ /MSWin32/i) {
        return 'windows';
    }
    else {
        return lc $osname; # Fallback: return raw OS name in lowercase
    }
}

sub detect_dark_mode {
	Logger::debug("#	detect_dark_mode");
    my ($os) = @_;
    $os ||= test_OS();

    if ($os eq "macos") {
        my $appearance = `defaults read -g AppleInterfaceStyle 2>/dev/null`;
        chomp $appearance;
        return $appearance =~ /Dark/i ? 1 : 0;
    }
    elsif ($os eq "linux") {
        # Example: check GTK theme settings (GNOME-based)
        my $theme = `gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null`;
        return $theme =~ /dark/i ? 1 : 0 if $theme;
    }

    return 0; # default to light mode if unknown
}

sub load_color_schema {
    my ($dark_mode) = @_;

    # ANSI escape codes for colors
    if ($dark_mode) {
        return {
            info    => "\e[38;5;81m",   # bright cyan
            warn    => "\e[38;5;214m",  # bright orange
            error   => "\e[38;5;196m",  # bright red
            success => "\e[38;5;82m",   # bright green
            debug   => "\e[38;5;244m",  # light grey
            reset   => "\e[0m",
        };
    }
    else {
        return {
            info    => "\e[34m",        # blue
            warn    => "\e[33m",        # yellow
            error   => "\e[31m",        # red
            success => "\e[32m",        # green
            debug   => "\e[90m",        # dark grey
            reset   => "\e[0m",
        };
    }
}

# --- Timing Utilities ---
my %_timers;

sub start_timer { $_timers{$_[0]} = [gettimeofday];
	Logger::debug("#	start_timer");
 }

sub stop_timer {
	Logger::debug("#	stop_timer");
  my $label = $_[0];
  return Logger::warn("[TIMER] No start time recorded for '$label'")
    unless $_timers{$label};
  my $elapsed = tv_interval($_timers{$label});
  Logger::debug(sprintf("[TIMER] %s took %.2f seconds", $label, $elapsed));
  return $elapsed;
}

sub run_mdfind {
    my %opts;
    my ($query, $opts) = @_;
    $opts ||= {};

    unless (defined $query && length $query) {
        Logger::warn("[WARN] run_mdfind called with no query");
        return [];
    }

    # Determine if we keep stderr or not
    my $stderr_redirect = $opts{debug_mdfind} ? '' : ' 2>/dev/null';

    my $cmd = sprintf('mdfind %s%s', shell_quote($query), $stderr_redirect);
    Logger::debug("[DEBUG] Running Spotlight query: $cmd");

    my @results = `$cmd`;
    chomp @results;

    Logger::info("[INFO] mdfind returned " . scalar(@results) . " results for query: $query");
    return \@results;
}

sub shell_quote {
    my ($str) = @_;
    return "''" unless defined $str && length $str;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

sub _find_latest_cache_file {
    my ($prefix) = @_;
    my $cache_dir = "cache";
    return unless -d $cache_dir;

    opendir(my $dh, $cache_dir) or return;
    my @files = grep { /^$prefix.*\.json$/ } readdir($dh);
    closedir($dh);

    return unless @files;

    # Sort newest first
    @files = sort { -M "$cache_dir/$a" <=> -M "$cache_dir/$b" } @files;
    return "$cache_dir/$files[0]";
}

sub get_mdls {
    my ($input) = @_;
    Utils::start_timer("mdls");

    # Normalize input to a list of file paths
    my @paths;
    if (ref $input eq 'HASH') {
        @paths = map { $input->{$_}->{source_path} // $input->{$_}->{path} } keys %$input;
    } elsif (ref $input eq 'ARRAY') {
        @paths = @$input;
    } elsif (!ref $input) {
        @paths = ($input);
    } else {
        die "[FATAL] get_mdls() called with unsupported input type";
    }

    my %results;
    my $count = 0;

    foreach my $path (@paths) {
        next unless defined $path && -f $path;

        # Escape single quotes for safe shell command
        (my $safe_path = $path) =~ s/'/'"'"'/g;

        my $mdls_output = `mdls '$safe_path' 2>&1`;
        if ($? != 0) {
            say "mdls puked on $path: $mdls_output";
            die "[FATAL] mdls failed for $path";
        }
        my %fields;
        for my $line (split /\n/, $mdls_output) {
            if ($line =~ /^(kMDItemFSCreationDate)\s+=\s+(.+)/)      { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemContentType)\s+=\s+(.+)/)      { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemDateAdded)\s+=\s+(.+)/)        { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemDisplayName)\s+=\s+(.+)/)      { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemFSName)\s+=\s+(.+)/)           { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemLogicalSize)\s+=\s+(.+)/)      { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemPhysicalSize)\s+=\s+(.+)/)     { $fields{$1} = $2 }
            elsif ($line =~ /^(kMDItemFSSize)\s+=\s+(.+)/)           { $fields{$1} = $2 }
        }

        $results{$path} = \%fields;
        $count++;
say "$count\t " . basename($path);
    }

    my $elapsed =  Utils::stop_timer("mdls");
    say "[MDLS] Processed metadata for $count files in ${elapsed}s.";

    return \%results;
}

#
# sub human_bytes {
#     my ($bytes, $opts) = @_;
# #     warn "[DEBUG] human_bytes opts: " . ($opts->{human_bytes} // 'undef') . "\n";
#     $opts ||= {};
#     return $opts->{human_bytes}
#         ? "$bytes bytes"
#         : Number::Bytes::Human::format_bytes($bytes) . "B";
# }

1;
