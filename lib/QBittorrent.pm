use common::sense;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use JSON;
use Time::Piece;
use File::Spec;

use lib 'lib';
use Logger;

package Utils;

sub load_cache {
    my ($type) = @_;
    unless ($type && $type =~ /^[a-z0-9_]+$/i) {
        Logger::warn("[WARN] load_cache() called without valid type — skipping load");
        return;
    }

    my $dir = "cache";
    my $latest = File::Spec->catfile($dir, "cache_${type}_latest.json");

    unless (-e $latest) {
        Logger::warn("[WARN] No cache file found for type '$type'");
        return;
    }

    my $data = decode_json(read_file($latest));
    Logger::info("[INFO] $type cache loaded from $latest (" . _count_entries($data) . " entries)");
    say __PACKAGE__ . " line " . __LINE__ . " \$latest=" . basename($latest);
    return ($data, $latest);
}

sub write_cache {
    my ($data, $type) = @_;
    my $dir = "cache";
    my $timestamp = localtime->strftime("%y.%m.%d-%H.%M");
    my $cache_file = File::Spec->catfile($dir, "cache_${type}_$timestamp.json");
    my $latest_file = File::Spec->catfile($dir, "cache_${type}_latest.json");

    my $json = JSON->new->utf8->pretty->canonical;
    eval {
        write_file($cache_file, $json->encode($data));
        write_file($latest_file, $json->encode($data));
        Logger::info("[INFO] $type cache written to $cache_file (" . (
            ref($data) eq 'HASH' ? scalar(keys %$data) : scalar(@$data)
        ) . " entries)");
        say __PACKAGE__ . " line " . __LINE__ . " \$cache_file=" . basename($cache_file);
    };
    if ($@) {
        Logger::error("[ERROR] Failed to write $type cache: $@");
        return;
    }
}

sub _count_entries {
    my ($data) = @_;
    return 0 unless $data;
    return ref($data) eq 'HASH' ? scalar(keys %$data) : scalar(@$data);
}

1;
