package Chunk;

use common::sense;
use Exporter 'import';
use Utils qw(human_bytes);
use Logger qw(debug info warn);

our @EXPORT_OK = qw(extract_chunks apply_chunking);
#
# sub extract_chunks {
#     my ($files_ref, $opts) = @_;
#     my $mode  = $opts->{chunk_mode}  || 'top';    # top | bottom | random
#     my $count = $opts->{chunk_count} || 5;
#     my @files = @$files_ref;
#
#     my @selected;
#     if ($mode eq 'top') {
#         @selected = _top_n(\@files, $count);
#         info("[CHUNK] Selected top $count largest files.");
#     } elsif ($mode eq 'bottom') {
#         @selected = _bottom_n(\@files, $count);
#         info("[CHUNK] Selected bottom $count smallest files.");
#     } elsif ($mode eq 'random') {
#         @selected = _random_n(\@files, $count);
#         info("[CHUNK] Selected $count random files.");
#     } else {
#         warn("[CHUNK] Unknown chunk mode: $mode");
#         return ();
#     }
#
#     # Display selected files for debug/dev
#     my $n = 0;
#     for my $file (@selected) {
#         my $size = -s $file;
#         my $size_str = human_bytes($size, $opts);
#         info("    ($size_str) - $file");
#         last if ++$n >= $count;
#     }
#     return @selected;
# }
#
#
# sub apply_chunking {
#     my ($files_ref, $chunk_id) = @_;
#     return @$files_ref unless defined $chunk_id;
#
#     my $total_chunks = $ENV{CHUNK_TOTAL} || 1;
#     my @files = @$files_ref;
#     my @chunked;
#
#     for (my $i = 0; $i < @files; $i++) {
#         push @chunked, $files[$i] if ($i % $total_chunks) == $chunk_id;
#     }
#
#     Logger::info("[CHUNK] Applied chunk filter: ID=$chunk_id / Total=$total_chunks (returned ".scalar(@chunked)."
# files)");
#     return \@chunked;
# }
#
#
# sub _top_n {
#     my ($files_ref, $count) = @_;
#     return sort { (-s $b) <=> (-s $a) } @$files_ref[0..$count-1];
# }
#
# sub _bottom_n {
#     my ($files_ref, $count) = @_;
#     return sort { (-s $a) <=> (-s $b) } @$files_ref[0..$count-1];
# }
#
# sub _random_n {
#     my ($files_ref, $count) = @_;
#     my @shuffled = @$files_ref;
#     for (my $i = @shuffled - 1; $i > 0; $i--) {
#         my $j = int(rand($i+1));
#         @shuffled[$i, $j] = @shuffled[$j, $i];
#     }
#     return @shuffled[0..$count-1];
# }

1;
