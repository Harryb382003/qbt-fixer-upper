package DevTools;

use common::sense;
use Data::Dumper;

use lib 'lib';
use Logger;

# DevTools - Development-only utilities
# Sprinkled 'say' statements with module + line for tracing during data churn
# Dumper outputs are gated behind debug flag

sub chunk {
    my ($data, $count) = @_;
    $count ||= 5;

    say "[DevTools:".__LINE__."] \$count => $count";

    unless (ref($data) eq 'HASH' || ref($data) eq 'ARRAY') {
        Logger::warn("[DEV] chunk() called with non-reference data");
        return $data;
    }

    my $type = ref $data;
    my $result;

    if ($type eq 'HASH') {
        my @keys = keys %$data;
        my @selected = @keys[0 .. ($count - 1 < $#keys ? $count - 1 : $#keys)];
        $result = { map { $_ => $data->{$_} } @selected };

        say "[DevTools:".__LINE__."] Hash keys selected => " . join(", ", @selected);
    }
    elsif ($type eq 'ARRAY') {
        my @selected = @$data[0 .. ($count - 1 < $#$data ? $count - 1 : $#$data)];
        $result = \@selected;

        say "[DevTools:".__LINE__."] Array count selected => " . scalar @selected;
    }

    if ($ENV{DEBUG}) {
        say "[DevTools:".__LINE__."] Dumper output for \$result:";
        say Dumper($result);
    }

    return $result;
}

1;
