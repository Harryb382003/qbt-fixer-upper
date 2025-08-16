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
    str2epoch
    get_mdls
);

# ---------------------------
# Debug sprinkle helper
# ---------------------------
sub _sprinkle {
    my ($varname, $value) = @_;
    my ($package, $filename, $line) = caller;
    my $shortfile = _short_path($filename);
    say "[SPRINKLE][$shortfile:$line] \$$varname = "
        . (ref $value ? Dumper($value) : $value)
        if $ENV{DEBUG};
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
sub load_cache {
    my ($type) = @_;
    my $file = "cache/cache_${type}_latest.json";

    unless (-e $file) {
        Logger::warn("[WARN] No cache file found for type '$type'");
        return (undef, $file);
    }

    my $json_text = read_file($file, binmode => ':utf8');
    my $data      = decode_json($json_text);

    Logger::info("[INFO] $type cache loaded from $file (" .
        (ref($data) eq 'HASH' ? scalar keys %$data : scalar @$data) .
        " entries)");
    _sprinkle("cache_$type", $data);

    return ($data, $file);
}

sub write_cache {
    my ($data, $type) = @_;
    my $timestamp = `date +%y.%m.%d-%H.%M`; chomp $timestamp;
    my $cache_file = "cache/cache_${type}_${timestamp}.json";
    my $latest_file = "cache/cache_${type}_latest.json";

    my $json = JSON->new->utf8->pretty->canonical;

    eval {
        write_file($cache_file,  $json->encode($data));
        write_file($latest_file, $json->encode($data));
        Logger::info("[INFO] $type cache written to $cache_file (" .
            (ref($data) eq 'HASH' ? scalar(keys %$data) : scalar(@$data)) .
            " entries)");
    };
    if ($@) {
        Logger::error("[ERROR] Failed to write $type cache: $@");
    }

    _sprinkle("cache_written_$type", $cache_file);
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

    _sprinkle("bdecode_" . basename($file_path), $decoded) if $decoded;

    return $decoded;
}

sub compute_infohash {
    my ($info) = @_;
    return unless $info && ref $info eq 'HASH';

    my $bencoded = Bencode::bencode($info->{info});
    my $hash     = sha1_hex($bencoded);

    _sprinkle("infohash", $hash);
    return $hash;
}

# ---------------------------
# Misc utilities
# ---------------------------
sub str2epoch {
    my ($str) = @_;
    # Placeholder — implement parsing if needed
    Logger::debug("[DEBUG] str2epoch called for '$str'");
    return time; # TEMP
}

sub get_mdls {
    my ($paths) = @_;
    return {} unless $paths && @$paths;

    my %metadata;
    foreach my $p (@$paths) {
        # Placeholder for actual mdls logic
        $metadata{$p} = {};
    }

    _sprinkle("mdls_results", \%metadata);
    return \%metadata;
}

1;
