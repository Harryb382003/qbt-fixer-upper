
package Utils;

use common::sense;
use Exporter 'import';
use Number::Bytes::Human ();
use File::Basename;
use Time::HiRes qw(gettimeofday tv_interval);
use JSON;
use File::Spec;
use File::Path qw(make_path);
use POSIX qw(strftime);
use File::Slurp;

our @EXPORT_OK = qw(
    test_OS
    detect_dark_mode
    extract_used_cli_opts
    start_timer
    stop_timer
    load_infohash_cache
    );


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


sub test_OS {
	Logger::debug("#	test_OS");
    my $osname = $^O;  # Perl's built-in OS name

    return "macos" if $osname =~ /darwin/i;
    return "linux" if $osname =~ /linux/i;
    return "freebsd" if $osname =~ /freebsd/i;
    return "unknown";
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


sub extract_used_cli_opts {
	Logger::debug("#	extract_used_cli_opts");
    my ($opts) = @_;
    my %used;

  foreach my $key (sort keys %$opts) {
    next unless defined $opts->{$key};
    $used{$key} = $opts->{$key};
  }
    return \%used;
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
