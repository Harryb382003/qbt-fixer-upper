package DevTools;

use common::sense;
use Utils;    # uses our always-available caching tools
use Logger;

# --- print_cache_summary ---
# Given a hashref of { label => label_name }, will try to load and summarize each cache.
#
# Example:
# DevTools::print_cache_summary({
#     parsed  => 'parsed',
#     dupes   => 'dupes',
#     zombies => 'zombies'
# });

sub chunk {
    my ($hashref, $size) = @_;
    $size ||= 5;

    my @keys = (keys %$hashref)[0 .. ($size - 1)];
    my %chunked = map { $_ => $hashref->{$_} } @keys;

    return \%chunked;
}


sub print_cache_summary {
    my ($labels_ref) = @_;
    Logger::info("\n--- Cache Summary ---");

    foreach my $desc (sort keys %$labels_ref) {
        my $label = $labels_ref->{$desc};
        my ($data, $file) = Utils::load_cache($label);

        if ($data) {
            my $count = (ref $data eq 'HASH') ? scalar(keys %$data)
                      : (ref $data eq 'ARRAY') ? scalar(@$data)
                      : 1;
            Logger::info("[DEV] $desc : loaded from cache -> $file ($count entries)");
        }
        else {
            Logger::info("[DEV] $desc : not used");
        }
    }
}

# Internal helper to match Utils.pm counting style
sub _count_entries {
    my ($data) = @_;
    return (ref $data eq 'HASH') ? scalar keys %$data
         : (ref $data eq 'ARRAY') ? scalar @$data
         : 1;
}
1;