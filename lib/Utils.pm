package Utils;

use Logger;
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use File::Slurp;
use Time::HiRes qw(gettimeofday tv_interval);
use JSON;
use Exporter 'import';
our @EXPORT_OK = qw(start_timer stop_timer);

# Always-available cache writer
sub write_cache {
    my ($data, $label) = @_;
    return unless defined $data && $label;

    my $dir = "cache";
    make_path($dir) unless -d $dir;

    my $latest_file = File::Spec->catfile($dir, "zombies_cache_${label}_latest.json");
    my $ts          = strftime("%y.%m.%d-%H%M", localtime);
    my $ts_file     = File::Spec->catfile($dir, "zombies_cache_${label}_${ts}.json");

    # Write both timestamped and latest versions
    my $json = JSON->new->utf8->pretty->encode($data);
    write_file($ts_file, $json);
    write_file($latest_file, $json);

    Logger::info("[INFO] Cache written for '$label' -> $latest_file (" .
                 _count_entries($data) . " entries)");

    return $latest_file;
}

# Always-available cache loader
sub load_cache {
    my ($label) = @_;
    return unless $label;

    my $file = File::Spec->catfile("cache", "zombies_cache_${label}_latest.json");
    return unless -e $file;

    my $data = decode_json(read_file($file));
    Logger::info("[INFO] Loaded '$label' from cache -> $file (" .
                 _count_entries($data) . " entries)");

    return ($data, $file);
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
sub start_timer { $_timers{$_[0]} = [gettimeofday]; }
	Logger::debug("#	start_timer");


sub stop_timer {
	Logger::debug("#	stop_timer");
  my $label = $_[0];
  return Logger::warn("[TIMER] No start time recorded for '$label'")
    unless $_timers{$label};
  my $elapsed = tv_interval($_timers{$label});
  Logger::debug(sprintf("[TIMER] %s took %.2f seconds", $label, $elapsed));
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
