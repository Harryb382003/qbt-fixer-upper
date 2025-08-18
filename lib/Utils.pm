package Utils;

use common::sense;
use Data::Dumper;

use File::Basename qw(basename);
use File::Spec;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Time::HiRes qw(gettimeofday tv_interval);
use Digest::SHA qw(sha1_hex);
use JSON qw(decode_json encode_json);

use lib 'lib';

use Logger;

use Exporter 'import';
our @EXPORT_OK = qw(
    load_cache
    write_cache
    compute_infohash
    bdecode_file
    get_mdls
    start_timer
    stop_timer
    sprinkle
);


# ---------------------------
# Misc utilities
# ---------------------------
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

sub deep_sort {
    my ($thing) = @_;
    if (ref $thing eq 'HASH') {
        return { map { $_ => deep_sort($thing->{$_}) } sort keys %$thing };
    }
    elsif (ref $thing eq 'ARRAY') {
        return [ map { deep_sort($_) } sort @$thing ];
    }
    else {
        return $thing;
    }
}

# ---------------------------
# Debug sprinkle helper
# ---------------------------
sub sprinkle {
    my ($varname, $value) = @_;
    my ($package, $filename, $line) = caller;
    my $shortfile = _short_path($filename);

    my $display;
    if (ref $value) {
        if ($ENV{DEBUG}) {
            $display = Dumper($value);   # full dump if DEBUG
        } else {
            $display = ref($value);      # just show the ref type (ARRAY, HASH, etc.)
        }
    } else {
        $display = $value;               # plain scalar
    }

    say "\n[SPRINKLE][$shortfile:$line] \$$varname = $display";
}

sub _short_path {
    my $path = shift;
    my @parts = File::Spec->splitdir($path);
    return join('/', @parts[0..1], '...', $parts[-1]) if @parts > 4;
    return $path;
}

# ---------------------------
# Cache handling
# ---------------------------

# Shared canonical JSON encoder (stable, no pretty-printing)
my $json_canon = JSON->new->utf8->canonical;

sub write_cache {
    my ($data, $type, $opts) = @_;
    my $timestamp   = `date +%y.%m.%d-%H.%M`; chomp $timestamp;
    my $cache_dir   = "cache";
    my $cache_file  = "$cache_dir/cache_${type}_${timestamp}.json";
    my $latest_file = "$cache_dir/cache_${type}_latest.json";

    make_path($cache_dir) unless -d $cache_dir;

    my $record_count = (ref($data) eq 'HASH') ? scalar(keys %$data) : scalar(@$data);

    # Build wrapper without digest first
    my $wrapper = {
        meta => {
            record_count => $record_count,
            type         => $type,
            written_at   => scalar localtime,
        },
        data => Utils::deep_sort($data),
    };

    my $json = JSON->new->utf8->pretty->canonical;
    my $encoded = $json->encode($wrapper);

    # Compute digest of entire encoded wrapper
    my $digest = sha1_hex($encoded);
    $wrapper->{meta}{digest} = $digest;

    # Re-encode with digest included
    $encoded = $json->encode($wrapper);

    eval {
        write_file($cache_file,  $encoded);
        write_file($latest_file, $encoded);

        # Cleanup old caches
        my $max_cache = $opts->{max_cache} // 3;
        my @files = sort { -M $a <=> -M $b }
                    glob("$cache_dir/cache_${type}_*.json");
        if (@files > $max_cache) {
            my @old = @files[$max_cache .. $#files];
            unlink @old;
            Logger::info("[CACHE] Cleaned up ".scalar(@old)." old '$type' caches");
        }

        Logger::info("[CACHE] Wrote '$type' cache ($record_count entries) → $cache_file");
    };
    if ($@) {
        Logger::error("[CACHE] Failed to write '$type' cache: $@");
    }
}

sub load_cache {
    my ($type) = @_;
    my $file = "cache/cache_${type}_latest.json";

    unless (-e $file) {
        Logger::warn("[CACHE] No '$type' cache file found");
        return (undef, $file, "not_found");
    }

    my $json_text = eval { read_file($file, binmode => ':utf8') };
    if ($@) {
        return (undef, $file, "read_error: $@");
    }

    my $wrapper = eval { decode_json($json_text) };
    if ($@) {
        return (undef, $file, "json_error: $@");
    }

    unless (ref($wrapper) eq 'HASH' && $wrapper->{meta} && $wrapper->{data}) {
        return (undef, $file, "invalid_format");
    }

    # Verify digest against the *entire file contents*
    my $expected = $wrapper->{meta}{digest};
    my $got      = sha1_hex($json_text);

    if ($expected ne $got) {
        Logger::error("[CACHE] Digest mismatch for '$type' cache ($file)\n".
                      " expected=$expected\n got     =$got");
        return (undef, $file, "digest_mismatch");
    }

    return ($wrapper->{data}, $file, undef); # success
}

sub _purge_cache_files {
    my ($type, $latest_file) = @_;

    Logger::warn("[CACHE] Purging unreadable '$type' cache");
    unlink $latest_file if -e $latest_file;

    # Kill timestamped siblings too
    my ($base) = $latest_file =~ m{^(.*)_latest\.json$};
    if ($base) {
        my @old = glob("${base}_*.json");
        unlink @old if @old;
    }
}



# ---------------------------
# Torrent helpers
# ---------------------------

sub bdecode_file {
    my ($file_path) = @_;
    return unless -e $file_path;

    open my $fh, '<:raw', $file_path or do {
        Logger::error("[ERROR] Cannot open $file_path: $!");
        return;
    };

    local $/;
    my $data = <$fh>;
    close $fh;

    my $decoded;
    eval { $decoded = Bencode::bdecode($data); 1 }
        or Logger::error("[ERROR] Failed to bdecode $file_path: $@");

#    sprinkle("bdecode_" . basename($file_path), $decoded) if $decoded;

    return $decoded;
}

sub compute_infohash {
    my ($info) = @_;
    return unless $info && ref $info eq 'HASH';

    my $bencoded = Bencode::bencode($info->{info});
    my $hash     = sha1_hex($bencoded);

    return $hash;
}

# ---------------------------
# MacOS utilities
# ---------------------------

sub run_mdfind {
 #   my %opts;
    my ($query, $opts) = @_;
    $opts ||= {};

    unless (defined $query && length $query) {
        Logger::warn("[WARN] run_mdfind called with no query");
        return [];
    }

    # Determine if we keep stderr or not
    my $stderr_redirect = $opts->{debug_mdfind} ? '' : ' 2>/dev/null';

    my $cmd = sprintf('mdfind %s%s', shell_quote($query), $stderr_redirect);
    Logger::debug("[DEBUG] Running Spotlight query: $cmd");

    my @results = `$cmd`;
    chomp @results;

    Logger::info("[INFO] mdfind returned " . scalar(@results) . " results for query: $query");
    return \@results;
}


sub get_mdls {
    my ($paths) = @_;
    return {} unless $paths && @$paths;

    my %metadata;
    foreach my $p (@$paths) {
        # Placeholder for actual mdls logic
        $metadata{$p} = {};
    }

    sprinkle("mdls_results", \%metadata);
    return \%metadata;
}

# ---------------------------
# Time and timers
# ---------------------------
my %TIMERS;

sub start_timer {
    my ($label) = @_;
    $TIMERS{$label} = [gettimeofday];  # store arrayref under label
    Logger::debug("Starting timer: $label") if defined $label;
}


sub stop_timer {
    my ($label) = @_;
    if (exists $TIMERS{$label}) {
        my $elapsed = tv_interval($TIMERS{$label});
        Logger::debug("Stopped timer: $label after ${elapsed}s") if defined $label;
        delete $TIMERS{$label};
        return $elapsed;
    } else {
        Logger::warn("Timer '$label' not found");
        return undef;
    }
}

sub _str2epoch {
    my ($str) = @_;
    return unless $str;
    my $epoch = eval { POSIX::strftime("%s", localtime(str2time($str))) };
    return $epoch || 0;
}

# ---------------------------
# Output coloring
# ---------------------------


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

1;
