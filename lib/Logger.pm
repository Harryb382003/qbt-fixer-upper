use common::sense;
use Data::Dumper;

use lib 'lib';
use Term::ANSIColor;
use File::Spec;
use File::Path qw(make_path);
package Logger;


my $log_fh;
my $log_file;
my $verbose = 0;
our $opts = {};

# Define two palettes
my %color_scheme_light = (
    INFO    => 'white',
    WARN    => 'yellow',
    ERROR   => 'red',
    DEBUG   => 'cyan',
    TRACE   => 'magenta',
    SUCCESS => 'green',
    DEV     => 'blue',
);


my %color_scheme_dark = (
    INFO    => 'bright_white',
    WARN    => 'bright_yellow',
    ERROR   => 'bright_red',
    DEBUG   => 'bright_cyan',
    TRACE   => 'bright_magenta',
    SUCCESS => 'bright_green',
    DEV     => 'bright_blue',
);

my %active_colors;


sub init {
	Logger::debug("#	init");
     my ($opts) = @_;
    $Logger::opts = $opts;

    # Pick color scheme based on dark mode flag
    if ($opts->{dark_mode}) {
        %active_colors = %color_scheme_dark;
    } else {
        %active_colors = %color_scheme_light;
    }

    # If invert-colors flag is set, swap the schemes
    if ($opts->{invert_colors}) {
    %active_colors = ($opts->{dark_mode})
        ? %color_scheme_light
        : %color_scheme_dark;
}

    # Make sure log dir exists
    my $log_dir = $opts->{log_dir} || '.';
    make_path($log_dir) unless -d $log_dir;

    $log_file = File::Spec->catfile($log_dir, "last.log");
    open($log_fh, '>', $log_file) or die "Cannot open log file $log_file: $!";
}

sub _log {
    my ($level, @messages) = @_;
    my $timestamp = scalar localtime;

    my $color     = $active_colors{$level} // 'reset';
    my $dump_ok   = $Logger::opts->{dump_debug} || 0;  # only dump debug/trace if set
    my $max_lines = 10;  # truncate console output

    foreach my $msg (@messages) {

        my $console_msg = $msg; # what goes to the screen
        my $file_msg    = $msg; # what goes to the log file

        if (ref $msg) {
            local $Data::Dumper::Terse    = 1;
            local $Data::Dumper::Indent   = 1;
            local $Data::Dumper::Sortkeys = 1;

            # For DEBUG/TRACE, only dump if explicitly allowed
            if ($level !~ /^(DEBUG|TRACE)$/ || $dump_ok) {
                $file_msg    = Dumper($msg);       # always full in log
                $console_msg = Dumper($msg);       # might get truncated below
            }
            else {
                $file_msg    = sprintf("[ref: %s]", ref $msg);
                $console_msg = $file_msg;
            }

            # Truncate console output unless dump_debug is set
            unless ($dump_ok) {
                my @lines = split /\n/, $console_msg;
                if (@lines > $max_lines) {
                    $console_msg = join("\n", @lines[0 .. $max_lines - 1]) . "\n... (truncated)";
                }
            }
        }

        # Console output (with color)
        print color($color) . "[$level] $console_msg" . color('reset') . "\n";

        # Always log to file without colors, full version
        if ($log_fh) {
            print $log_fh "[$timestamp] [$level] $file_msg\n";
        }
    }
}

sub _timestamp {
	Logger::debug("#	_timestamp");
    my @t = localtime();
    return sprintf("%02d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

# Public logging methods
sub info    { _log("INFO",    shift); }
sub warn    { _log("WARN",    shift); }
sub error   { _log("ERROR",   shift); }
sub debug   { _log("DEBUG",   shift) if $verbose >= 2; }
sub trace   { _log("TRACE",   shift) if $verbose >= 3; }
sub success { _log("SUCCESS", shift); }
sub dev {
	Logger::debug("#	dev");
    my ($msg) = @_;
    return unless $opts->{dev_mode};
    info("[DEV] $msg");
}

# Log used CLI options
sub log_used_opts {
	Logger::debug("#	log_used_opts");
    my ($used) = @_;
    return unless $used && ref $used eq 'HASH';

    Logger::info("[CONFIG] CLI options used:");
    foreach my $key (sort keys %$used) {
        my $val = $used->{$key};

        if (ref $val eq 'ARRAY') {
            Logger::info(sprintf("  %-15s :", $key));
            foreach my $item (@$val) {
                Logger::info(sprintf("  %-15s   %s", '', $item));
            }
        }
        elsif (ref $val eq 'HASH') {
            Logger::info(sprintf("  %-15s :", $key));
            foreach my $subkey (sort keys %$val) {
                Logger::info(sprintf("  %-15s   %s => %s", '', $subkey, $val->{$subkey}));
            }
        }
        else {
            my $formatted_val = ($val eq '1') ? 'yes' :
                                ($val eq '0') ? 'no'  : $val;
            Logger::info(sprintf("  %-15s : %s", $key, $formatted_val));
        }
    }
}

1;
