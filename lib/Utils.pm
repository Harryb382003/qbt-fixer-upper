package Utils;

use common::sense;
use Data::Dumper;

use File::Copy qw(move);
use File::Basename qw(basename dirname);
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

sub normalize_filename {
    use File::Basename qw(basename dirname);
    use File::Copy qw(move);

    my ($meta, $colliders, $opts) = @_;
    my $old_path     = $meta->{source_path};
    my $torrent_name = $meta->{name};
    my $tracker      = $meta->{tracker};
    my $comment      = $meta->{comment};
    # 🚫 Allow disabling normalization via opts
    if (!$opts->{normalize}) {
        Logger::debug("[normalize_filename] Normalization disabled by opts → $old_path");
        return $old_path;
    }

    # --- Skip rename if path is under protected buckets
    if ($old_path =~ m{/(Completed_torrents|BT_backup|Downloaded_torrents)}i) {
        Logger::debug("[normalize_filename] Protected bucket match, no rename: $old_path");
        return $old_path;
    }

    # --- use torrent_name directly (filesystem safe already)
    my $safe_name = $torrent_name;
    $safe_name .= ".torrent" unless $safe_name =~ /\.torrent$/i;

    my $dir      = dirname($old_path);
    my $new_path = "$dir/$safe_name";
    my $base     = basename($new_path);

    # Step 1: Already marked as collider → jump to tracker-prefixed version
    if (exists $colliders->{$base}) {
        my $prefixed = _prepend_tracker($tracker, $comment, $safe_name);
        my $prefixed_path = "$dir/$prefixed";
        Logger::warn("[normalize_filename] $base already marked collider → using $prefixed_path");
        return $prefixed_path;
    }

    # Step 2: Actual filesystem collision
    if (-e $new_path && $old_path ne $new_path) {
        Logger::warn("\n[normalize_filename] COLLISION: $old_path → $new_path");

        # mark this base as a collider
        $colliders->{$base} = 1;

        # retry with tracker/comment prefix
        my $prefixed = _prepend_tracker($tracker, $comment, $safe_name);
        my $prefixed_path = "$dir/$prefixed";

        if (-e $prefixed_path) {
            Logger::warn("[normalize_filename] Tracker-prefixed target also
                exists: $prefixed_path — MANUAL REVIEW REQUIRED");
            $colliders->{manual}{$base} = {
                original => $old_path,
                target   => $prefixed_path,
                tracker  => $tracker,
                comment  => $comment,
            };
            return $old_path;
        }

        if (move($old_path, $prefixed_path)) {
            Logger::info("[normalize_filename] Renamed (collider) $old_path → $prefixed_path");
            return $prefixed_path;
        } else {
            Logger::warn("[normalize_filename] Failed to rename collider $old_path → $prefixed_path: $!");
            return $old_path;
        }
    }

    # Step 3: No collision, safe to rename
    if ($old_path ne $new_path) {
        if (move($old_path, $new_path)) {
            Logger::info("[normalize_filename] Renamed (clean) $old_path → $new_path");
            return $new_path;
        } else {
            Logger::warn("[normalize_filename] Failed to rename $old_path → $new_path: $!");
            return $old_path;
        }
    }

    # Step 4: Nothing to do
    return $old_path;
}

# --- helper for tracker/comment prepend ---
# sub _prepend_tracker {
#     my ($tracker, $comment, $filename) = @_;
#
#     my $prefix = "";
#     if ($tracker) {
#         $tracker =~ s{https?://}{};
#         $tracker =~ s{/.*$}{};
#         $tracker =~ s/[^\w\-\.]+/_/g;
#         $prefix = $tracker;
#     }
#
#     if ($comment && $comment =~ /(\d{6,})/) {
#         $prefix .= " - $1";
#     }
#
#     return $prefix ? "[$prefix] - $filename" : $filename;
# }

# --- helper ---
sub _prepend_tracker {
    my ($tracker, $comment, $filename) = @_;

    my $prefix;
    if ($tracker) {
        $prefix = _shorten_tracker($tracker);
    } elsif ($comment && $comment =~ m{https?://([^/]+)}) {
        $prefix = _shorten_tracker($1);
    }

    return $filename unless $prefix;
    return "[$prefix] - $filename";
}

sub _shorten_tracker {
    my ($url) = @_;
    return '' unless $url;

    # Extract hostname
    my $host;
    if ($url =~ m{https?://([^/:]+)}) {
        $host = $1;
    } else {
        $host = $url;  # fallback
    }

    # Strip leading "tracker."
    $host =~ s/^tracker\.//i;

    # Take the first meaningful label
    my @parts = split(/\./, $host);
    my $short = $parts[0] // $host;

    # Uppercase
    $short = uc $short;

    return $short;
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

sub derive_qbt_context {
    my ($torrent_path) = @_;
    my ($vol, $dir, $file) = File::Spec->splitpath($torrent_path);

    my $save_path  = $dir;  # fallback: directory where the .torrent was found
    my $category   = "";

    # Infer category from directory naming
    if ($dir =~ /DUMP/i) {
        $category = "DUMP";
    }
    elsif ($dir =~ /FREELEECH/i) {
        $category = "_FREELEECH";
    }
    elsif ($dir =~ /UNREGISTERED/i) {
        $category = "UNREGISTERED";
    }

    return ($save_path, $category);
}

sub sanity_check_payload {
    my ($meta, $save_path, $bucket) = @_;
    my @issues;
    my $valid = 1;

    foreach my $file (@{ $meta->{files} }) {
        my $path = File::Spec->catfile($save_path, $file->{path});
        if (!-e $path) {
            push @issues, "missing:$path";
            $valid = 0;
            next;
        }

        my $size_fs = -s $path;
        my $size_meta = $file->{length};

        if ($size_fs != $size_meta) {
            # 0-byte allowance
            if ($size_fs == 0) {
                push @issues, "zero_byte:$path";
            } else {
                push @issues, "size_mismatch:$path ($size_fs != $size_meta)";
                $valid = 0;
            }
        }
    }

    # Special rule: DUMP bucket completion threshold
    if ($bucket eq 'dump') {
        my $total_bytes = $meta->{length};
        my $have_bytes  = 0;
        foreach my $file (@{ $meta->{files} }) {
            my $path = File::Spec->catfile($save_path, $file->{path});
            $have_bytes += (-e $path ? (-s $path) : 0);
        }
        my $completion = $total_bytes ? ($have_bytes / $total_bytes) : 0;

        # 1% per GB rule
        my $threshold = ($total_bytes / (1024*1024*1024)) * 0.01;
        if ($completion < $threshold) {
            push @issues, "below_threshold: " . sprintf("%.2f%% < %.2f%%", $completion*100, $threshold*100);
            $valid = 0;
        }
    }

    return {
        valid  => $valid,
        issues => \@issues,
    };
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
