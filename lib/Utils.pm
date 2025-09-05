package Utils;

use common::sense;
use Data::Dumper;


use Cwd qw(getcwd);
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
    locate_items
    locate_torrents
    load_cache
    write_cache
    compute_infohash
    bdecode_file
    get_mdls
    start_timer
    stop_timer
    normalize_to_arrayref
    maybe_translate
    parse_chunk_spec
    chunk
    payload_ok
    derive_save_path
    prompt_between_chunks
    pause_between_chunks
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

sub locate_torrents {
    my ($opts) = @_;
    $opts ||= {};

    # Build prune roots from your existing ignore set (export_dir_fin)
    my @prune;
    if (ref $opts->{export_dir_fin} eq 'ARRAY') {
        push @prune, @{ $opts->{export_dir_fin} };
    } elsif ($opts->{export_dir_fin}) {
        push @prune, $opts->{export_dir_fin};
    }

    my $paths = locate_items({
        ext   => 'torrent',
        kind  => 'file',
        prune => \@prune,
    });

    return wantarray ? @$paths : $paths;
}

sub locate_items {
    my ($args) = @_;
    $args ||= {};

    Logger::debug("#\tlocate_items");
    start_timer("locate_items");

    # Check Spotlight availability
    my $mdfind_path = `command -v mdfind 2>/dev/null`;
    chomp $mdfind_path;
    my $has_mdfind = ($mdfind_path && -x $mdfind_path) ? 1 : 0;

    unless ($has_mdfind) {
        # no code has been written to use File::Find or any other backend
        # this is a placeholder for future Linux/BSD compatibility
        Logger::error("[Utils] mdfind not available; File::Find fallback not yet implemented");
        stop_timer("locate_items");
        return wantarray ? () : [];
    }

    my $kind  = lc($args->{kind} // 'any');
    my $name  = $args->{name};
    my $ext   = $args->{ext};
    my $limit = $args->{limit};
    my @prune = @{ $args->{prune} // [] };

    # Build a single string command with proper quoting.
    my $cmd;
    if (defined $name && length $name) {
        my $qname = _sh_single_quote($name);
        $cmd = "mdfind -name $qname 2>/dev/null";
    } elsif (defined $ext && length $ext) {
        my $query = qq{kMDItemFSName == "*.$ext"cd};
        my $q     = _sh_single_quote($query);
        $cmd = "mdfind $q 2>/dev/null";
    } else {
        # legacy default: find *.torrent
        my $query = q{kMDItemFSName == "*.torrent"cd};
        my $q     = _sh_single_quote($query);
        $cmd = "mdfind $q 2>/dev/null";
    }

    my @out = `$cmd`;
    chomp @out;

    # filter: existing, dedup, kind, prune, limit
    my %seen;
    my @results = grep { !$seen{$_}++ } grep { defined $_ && length $_ } @out;

    # existence (allow symlinks)
    @results = grep { -e $_ || -l $_ } @results;

    # kind filter
    if    ($kind eq 'file') { @results = grep { -f $_ } @results; }
    elsif ($kind eq 'dir')  { @results = grep { -d $_ } @results; }

    # prune prefixes
    if (@prune) {
        @results = grep {
            my $p = $_; my $ok = 1;
            for my $bad (@prune) {
                next unless defined $bad && length $bad;
                if (index($p, $bad) == 0) { $ok = 0; last }
            }
            $ok
        } @results;
    }

    # limit if requested
    if (defined $limit && $limit =~ /^\d+$/ && $limit > 0 && @results > $limit) {
        @results = @results[0 .. $limit-1];
    }

    Logger::info("[MAIN] Located " . scalar(@results) . " item(s) via Spotlight");
    stop_timer("locate_items");

    return wantarray ? @results : \@results;
}

sub _under_dir {
    my ($path, $root) = @_;
    require File::Spec;
    my $P = File::Spec->rel2abs($path); $P =~ s{/\z}{};
    my $R = File::Spec->rel2abs($root); $R =~ s{/\z}{};
    return ($P eq $R) || (index($P, "$R/") == 0);
}

sub _sh_single_quote {
    my ($s) = @_;
    $s //= '';
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub normalize_to_arrayref {
    my $val = shift;
    return [] unless defined $val;
    return ref($val) eq 'ARRAY' ? $val : [$val];
}

sub parse_chunk_spec {
    my ($spec) = @_;
    $spec //= '5';

    my ($n) = $spec =~ /(\d+)/;
    die "[chunk] missing or invalid size in '$spec'\n" unless defined $n && $n > 0;

    my $flags = lc($spec =~ s/\d+//r // '');   # strip digits, keep flags
    my $has_auto   = ($flags =~ /a/) ? 1 : 0;
    my $has_manual = ($flags =~ /m/) ? 1 : 0;

    # if both a & m given, prefer manual (be conservative)
    if ($has_auto && $has_manual) {
        $has_auto = 0;
        Logger::warn("[chunk] both 'a' and 'm' provided; using manual prompt (m)");
    }

    return ($n, $has_auto, $has_manual);
}

sub chunk {
    my ($data, $count) = @_;
    $count ||= 5;

    unless (ref($data) eq 'HASH' || ref($data) eq 'ARRAY') {
        Logger::warn("[Utils] chunk() called with non-reference data");
        return $data;
    }

    my $type = ref $data;
    my $result;

    if ($type eq 'HASH') {
        my @keys = keys %$data;
        my @selected = splice(@keys, 0, $count);  # consume keys
        $result = { map { $_ => delete $data->{$_} } @selected };
    }
    elsif ($type eq 'ARRAY') {
        my @selected = splice(@$data, 0, $count); # consume items
        $result = \@selected;
    }
    return $result;
}

sub payload_ok {
    my ($metadata, $opts) = @_;
    my $files = $metadata->{files} // [];
    unless (@$files) {
        return {
            ok => 0,
            reason => "no-file-list",
            details => {
                missing => [],
                mismatched => [],
                zeros => 0,
                present => 0,
                total => 0,
                tested => [],
            },
            needs_corroboration => 0,
        }
    }

    my $is_mac = ($^O eq 'darwin');

    # -------- determine multi vs single and preferred lookup key --------
    # files entries are usually HASH { path, length }, but guard if string
    my $first_rel =
        (!@$files)                   ? undef
      : (ref($files->[0]) eq 'HASH') ? ($files->[0]{path} // '')
      :                                ($files->[0] // '');

    my $is_multi = (@$files > 1) || (defined($first_rel) && $first_rel =~ m{/});

    # torrent "display name"
    my $name = $metadata->{name};
    unless (defined $name && length $name) {
        my $p = $first_rel // '';
        ($name) = ($p =~ m{^([^/]+)/}) ? $1 : $p;
    }
    $name //= '';

    # for multi-file, prefer the top folder from the file list, not the display name
    my $top = undef;
    if ($is_multi && defined $first_rel) {
        if ($first_rel =~ m{^([^/]+)/}) { $top = $1; }
        else { $top = $name; }  # fallback
    }

    my (@missing, @mismatched, @tested);
    my ($zeros, $present) = (0, 0);

    # -------- resolve on disk --------
    my $hit_path;

    if ($is_mac) {
        if ($is_multi) {
            # directory-first for multi-file torrents
            if (defined $top && length $top) {
                my @dirs = locate_payload_dirs_named($top);
                Logger::debug("[trace:dir] top-from-files = [ $top ] dir_hits=" . scalar(@dirs));
                $hit_path = $dirs[0] if @dirs;
                Logger::info("[PAYLOAD] resolve name = [ $top ] hit_path=" . (defined $hit_path ? $hit_path :
'(none)'));
            }
            # if we didn't find the top folder, skip cleanly (do NOT guess a single file)
            unless (defined $hit_path && length $hit_path) {
                Logger::info("[probe] hit_path = (undef)");
                Logger::info("[probe] exists = 0 is_file = 0 is_dir = 0");
                Logger::info("[probe] stat_size=(undef)");
                Logger::info("[probe] tested_name = " . (defined $top ? $top : "(undef)"));
                Logger::warn("[PAYLOAD] skip reason = missing-files tested = " . (defined $top ? $top : "(undef)"));
                return {
                    ok      => 0,
                    reason  => "missing-files",
                    details => {
                        missing    => [ (defined $top ? $top : $name) ],
                        mismatched => [],
                        zeros      => 0,
                        present    => 0,
                        total      => scalar(@$files),
                        tested     => [ (defined $top ? $top : $name) ],
                    },
                    needs_corroboration => 0,
                };
            }
        } else {
            # single-file: resolve by file name; prefer size when available
            my $base = $first_rel // $name;       # single-file should be basename already
            my $expected_size = undef;
            if (@$files == 1) {
                if (ref($files->[0]) eq 'HASH') { $expected_size = $files->[0]{length}; }
            }
            my ($file_hit) = locate_payload_files_named($base, $expected_size);
            $hit_path = $file_hit if defined $file_hit;
            Logger::info("[PAYLOAD] resolve name = [$base] hit_path=" . (defined $hit_path ? $hit_path : '(none)'));
        }
    }

    # -------- if nothing resolved, skip --------
    unless (defined $hit_path && length $hit_path) {
        Logger::info("[probe] hit_path = " . (defined $hit_path ? $hit_path : "(undef)"));
        Logger::info("[probe] exists = "
            . (defined $hit_path && -e $hit_path ? 1 : 0)
            . " is_file=" . (defined $hit_path && -f $hit_path ? 1 : 0)
            . " is_dir="  . (defined $hit_path && -d $hit_path ? 1 : 0)
        );
        my $size_str;
        if (defined $hit_path) {
            my @s = stat($hit_path);
            $size_str = @s ? $s[7] : "stat-failed($!)";
        } else {
            $size_str = "(undef)";
        }
        Logger::info("[probe] stat_size = $size_str");
        Logger::info("[probe] tested_name = " . (defined($is_multi ? $top : $name) ? ($is_multi ? $top : $name) :
"(undef)"));
        Logger::warn("[PAYLOAD] skip reason = missing-files tested=" . ($is_multi ? ($top // $name) : $name));
        return {
            ok      => 0,
            reason  => "missing-files",
            details => {
                missing    => [ $is_multi ? ($top // $name) : $name ],
                mismatched => [],
                zeros      => 0,
                present    => 0,
                total      => scalar(@$files),
                tested     => [ $is_multi ? ($top // $name) : $name ],
            },
            needs_corroboration => 0,
        };
    }

    # -------- probe what we found; dir → ok; file → size check --------
    Logger::info("[probe] hit_path = " . (defined $hit_path ? $hit_path : "(undef)"));
    Logger::info("[probe] exists = "
        . (-e $hit_path ? 1 : 0)
        . " is_file=" . (-f $hit_path ? 1 : 0)
        . " is_dir="  . (-d $hit_path ? 1 : 0)
    );
    my $size_str;
    {
        my @s = stat($hit_path);
        $size_str = @s ? $s[7] : "stat-failed($!)";
    }
    Logger::info("[probe] stat_size = $size_str");
    Logger::info("[probe] tested_name = " . ($is_multi ? ($top // $name) : $name));

    my $exists = (-e $hit_path) || (-l $hit_path);
    push @tested, $hit_path;

    unless ($exists) {
        push @missing, $hit_path;
        Logger::warn("[PAYLOAD] skip reason = missing-files tested=" . ($is_multi ? ($top // $name) : $name));
        return {
            ok      => 0,
            reason  => "missing-files",
            details => {
                missing    => \@missing,
                mismatched => [],
                zeros      => 0,
                present    => 0,
                total      => scalar(@$files),
                tested     => \@tested,
            },
            needs_corroboration => 0,
        };
    }

    my $is_dir = (-d $hit_path) ? 1 : 0;
    my $size   = undef;

    if ($is_dir) {
        $present++;
    } else {
        # file: compute size (mdls on mac if available)
        my $sz = -s $hit_path; $sz = 0 unless defined $sz;
        if ($is_mac) {
            my $out = `mdls -name kMDItemFSSize -raw "$hit_path" 2>/dev/null`; chomp $out;
            $sz = 0 + $out if defined $out && $out ne '' && $out ne '(null)' && $out =~ /^\d+$/;
        }
        $size = $sz;
        $present++;

        # compare with expected only for single-file torrents
        my @mm;
        my $expected = undef;
        if (@$files == 1 && ref($files->[0]) eq 'HASH') {
            $expected = $files->[0]{length};
        }
        if (!defined $size) {
            push @mm, { path => $hit_path, expected => $expected, got => undef };
        } elsif ($size == 0) {
            $zeros++;
        } elsif (defined $expected && $expected =~ /^\d+$/ && $size != $expected) {
            push @mm, { path => $hit_path, expected => $expected, got => $size };
        }
        @mismatched = @mm if @mm;
    }

    Logger::info("[PAYLOAD] ok found_path = $hit_path");

    $metadata->{resolved_path} = $hit_path;
    return {
        ok      => 1,
        reason  => "ok",
        details => {
            missing    => [],
            mismatched => \@mismatched,
            zeros      => $zeros,
            present    => $present,
            total      => scalar(@$files),
            tested     => \@tested,
        },
        needs_corroboration => ($zeros > 0 ? 1 : 0),
    };
}

sub locate_payload_files_named {
    my ($name, $size_opt) = @_;
    return () unless defined $name && length $name;
    return () unless $^O eq 'darwin';

    my $mdfind = `command -v mdfind 2>/dev/null`; chomp $mdfind;
    return () unless $mdfind && -x $mdfind;

    Logger::debug("\n[files_named] search name=[$name]");

    my @hits;

    # 1) exact FSName + size (if numeric size given)
    if (defined $size_opt && $size_opt =~ /^\d+$/) {
        my $q   = qq{kMDItemFSName=="$name" && kMDItemFSSize==$size_opt};
        my $cmd = "mdfind " . _shq($q) . " 2>/dev/null";
        my @out = `$cmd`; chomp @out;
        @hits = grep { -f $_ && $_ !~ /\.torrent$/i } @out;
        if (@hits) {
            Logger::debug("[files_named] exact+size hit: " . scalar(@hits));
            Logger::debug("  [cand] $_") for @hits;
            return wantarray ? @hits : $hits[0];
        }
    }

    # 2) exact FSName (no size)
    {
        my $q   = qq{kMDItemFSName=="$name"};
        my $cmd = "mdfind " . _shq($q) . " 2>/dev/null";
        my @out = `$cmd`; chomp @out;
        @hits = grep { -f $_ && $_ !~ /\.torrent$/i } @out;
        if (@hits) {
            Logger::debug("[files_named] exact-name hit: " . scalar(@hits));
            Logger::debug("  [cand] $_") for @hits;
            return wantarray ? @hits : $hits[0];
        } else {
            Logger::debug("[files_named] exact-name miss");
        }
    }

    # 3) glob by name, then rank by extension (videos first, images last)
    {
        my $cmd = "mdfind -name " . _shq($name) . " 2>/dev/null";
        my @out = `$cmd`; chomp @out;
        @hits = grep { -f $_ && $_ !~ /\.torrent$/i } @out;

        if (@hits) {
            Logger::debug("[files_named] glob hit: " . scalar(@hits));
            Logger::debug("  [cand] $_") for @hits;

            my %rank = (
                (map { $_ => 1 } qw(mp4 mkv mov avi wmv ts m4v mpg mpeg flv)),
                (map { $_ => 2 } qw(iso img bin cue nrg)),
                (map { $_ => 3 } qw(mp3 flac aac m4a ogg wav)),
                (map { $_ => 4 } qw(sub srt idx vob)),
                (map { $_ => 5 } qw(jpg jpeg png gif bmp webp heic)),
            );

            my $ext = sub {
                my ($p) = @_;
                return '' unless defined $p;
                return lc($1) if $p =~ /\.([^.]+)$/;
                return '';
            };

            @hits = sort {
                my $ea = $ext->($a); my $eb = $ext->($b);
                my $ra = exists $rank{$ea} ? $rank{$ea} : 50;
                my $rb = exists $rank{$eb} ? $rank{$eb} : 50;
                $ra <=> $rb
            } @hits;

            Logger::debug("[files_named] glob-select $hits[0]") if @hits;
            return wantarray ? @hits : $hits[0];
        }
    }

    return ();

    sub _shq { my ($s)=@_; $s//= ''; $s =~ s/'/'"'"'/g; return "'$s'"; }
}

sub derive_save_path {
    my ($metadata, $opts) = @_;

    # qBT-managed roots we must never target
    my @managed = (
        @{ $opts->{export_dir}     || [] },
        @{ $opts->{export_dir_fin} || [] },
    );
    my %managed = map {
        my $p = $_ // '';
        $p =~ s{/\z}{};
        $p => 1
    } grep { defined && length } @managed;

    return undef unless defined $metadata->{resolved_path} && length $metadata->{resolved_path};

    require File::Basename;
    require File::Spec;

    my $rp        = $metadata->{resolved_path};
    my $candidate = (-d $rp) ? $rp : File::Basename::dirname($rp);
    my $abs       = File::Spec->rel2abs($candidate // '');
    $abs =~ s{/\z}{};

    # refuse exact managed roots or their children
    return undef if $managed{$abs};
    for my $root (keys %managed) {
        next unless length $root;
        return undef if index($abs, "$root/") == 0;
    }

    return -d $abs ? $abs : undef;  # fall back to qBT default if missing
}

sub _first_component {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    return $1 if $p =~ m{^([^/]+)/};
    return $p  if $p !~ m{/};
    return undef;
}

sub locate_payload_dirs_named {
    my ($name) = @_;
    return () unless defined $name && length $name;
    return () unless $^O eq 'darwin';

    my $mdfind = `command -v mdfind 2>/dev/null`; chomp $mdfind;
    return () unless $mdfind && -x $mdfind;

    start_timer("find_payload");
    Logger::debug("#\tlocate_payload_dirs_named");

    my @dirs;

    # 1) exact FSName (directory)
    {
        my $q   = qq{kMDItemFSName=="$name"};
        my $cmd = "mdfind " . _shq($q) . " 2>/dev/null";
        my @out = `$cmd`; chomp @out;
        @dirs = grep { -d $_ } @out;
        if (@dirs) {
            Logger::info("[MAIN] Located " . scalar(@dirs) . " dirs for '$name'");
            return @dirs;
        }
    }

    # 2) glob by name (directory only) — catches spacing/diacritic variants
    {
        my $cmd = "mdfind -name " . _shq($name) . " 2>/dev/null";
        my @out = `$cmd`; chomp @out;
        @dirs = grep { -d $_ } @out;
        Logger::info("[MAIN] Located " . scalar(@dirs) . " dirs for '$name'");
        return @dirs if @dirs;
    }

    Logger::info("[MAIN] Located 0 dirs for '$name'");
    stop_timer("find_payload");
    return ();

    # local single-quote helper (kept inside the sub)
    sub _shq { my ($s)=@_; $s//= ''; $s =~ s/'/'"'"'/g; return "'$s'"; }
}

sub _mdfind_list {
    my ($query, $name) = @_;
    my $cmd;
    if (defined $query) {
        $cmd = "mdfind " . _shq($query) . " 2>/dev/null";
    } elsif (defined $name) {
        $cmd = "mdfind -name " . _shq($name) . " 2>/dev/null";
    } else {
        return ();
    }
    my @out = `$cmd`;
    chomp @out;
    @out = grep { defined $_ && length $_ } @out;
    # Drop non-existent (stale index) entries; we only want live hits
    @out = grep { -e $_ || -l $_ } @out;
    return @out;
}

sub _dirname_fast {
    my ($p) = @_;
    return undef unless defined $p && length $p;
    $p =~ s{/+$}{};
    $p =~ s{[^/]+$}{};
    $p =~ s{/+$}{};
    return length($p) ? $p : '/';
}

sub ensure_temp_ignore_dir {
    my ($opts) = @_;
    my $cwd = getcwd();
    my $dir = File::Spec->catdir($cwd, 'temp_ignore');

    unless (-d $dir) {
        make_path($dir);
    }

    # remember explicitly
    $opts->{temp_ignore_dir} = $dir;

    # normalize & append to export_dir_fin (your “ignored contents” set)
    my $arr = $opts->{export_dir_fin};
    if (ref($arr) ne 'ARRAY') {
        $arr = defined $arr ? [$arr] : [];
    }
    # avoid duplicates (string match)
    my %seen = map { $_ => 1 } @$arr;
    push @$arr, $dir unless $seen{$dir};
    $opts->{export_dir_fin} = $arr;

    return $dir;
}

sub quarantine_torrent {
    my ($torrent_path, $opts, $why) = @_;
    return 0 unless defined $torrent_path && -f $torrent_path;

    my $sink = $opts->{temp_ignore_dir} // ensure_temp_ignore_dir($opts);
    my $base = basename($torrent_path);
    my $dest = File::Spec->catfile($sink, $base);

    if ($sink && index($torrent_path, "$sink/") == 0) {
        return 1;
    }

    # uniquify if already exists
    if (-e $dest) {
        my ($stem,$ext) = ($base =~ /^(.*?)(\.[^.]*)?$/);
        my $i = 1;
        while (-e File::Spec->catfile($sink, sprintf("%s.%d%s", $stem, $i, ($ext//'')))) {
            $i++;
        }
        $dest = File::Spec->catfile($sink, sprintf("%s.%d%s", $stem, $i, ($ext//'')));
    }

    if (move($torrent_path, $dest)) {
        Logger::summary("[SKIP→TEMP] $base reason=" . ($why // 'unspecified') . " → $dest");
        return 1;
    } else {
        Logger::warn("[SKIP→TEMP][FAILED] $base reason=" . ($why // 'unspecified') . " err=$!");
        return 0;
    }
}


# sub pause_between_chunks {
#     my ($has_auto, $delay_s) = @_;
#     return unless $has_auto;
#     $delay_s = 1.5 unless defined $delay_s;  # default breather
#     select(undef, undef, undef, $delay_s);   # sub-second sleep
# }
#
# sub prompt_between_chunks {
#     my ($has_manual, $processed) = @_;
#     return 1 unless $has_manual;             # no prompt -> continue
#     return 1 if !-t *STDIN;                  # no TTY -> continue
#     print "[MAIN] Processed $processed. Continue? (y/n) ";
#     chomp(my $ans = <STDIN>);
#     return $ans =~ /^y?$/i;                  # Enter or 'y' -> continue
# }
#

# sub _strip_trailing_slash {
#     my ($p) = @_;
#     return undef unless defined $p;
#     $p =~ s{/+$}{};
#     return $p;
# }

# sub _common_dir_prefix {
#     my @paths = @_;
#     return undef unless @paths;
#     # Split all into components
#     my @parts = map { [ grep { length } split m{/+}, $_ ] } @paths;
#     my $minlen = 0 + (sort { $a <=> $b } map { scalar(@$_) } @parts)[0];
#
#     my @common;
#     for my $i (0 .. $minlen-1) {
#         my $seg = $parts[0][$i];
#         last unless defined $seg;
#         for my $p (@parts[1..$#parts]) {
#             last unless defined $p->[$i] && $p->[$i] eq $seg;
#         }
#         # verify all equal at this depth
#         my $all_eq = 1;
#         for my $p (@parts[1..$#parts]) {
#             if (!defined $p->[$i] || $p->[$i] ne $seg) { $all_eq = 0; last }
#         }
#         last unless $all_eq;
#         push @common, $seg;
#     }
#
#     return undef unless @common;
#     return '/' . join('/', @common);
# }
#
# sub _join_path {
#     my ($base, $rel) = @_;
#     $base //= ''; $rel //= '';
#     return $rel =~ m{^/} ? $rel : ($base =~ m{/$} ? $base.$rel : "$base/$rel");
# }
#
# sub _probe_file {
#     my ($path, $is_mac) = @_;
#     return (0, undef, 0) unless defined $path && length $path;
#     return (0, undef, 0) unless -e $path || -l $path;
#     return (1, undef, 1) if -d $path;          # directory present
#     my $size = -s $path; $size = 0 unless defined $size;
#     if ($is_mac && -f $path) {
#         my $out = `mdls -name kMDItemFSSize -raw "$path" 2>/dev/null`; chomp $out;
#         $size = 0 + $out if defined $out && $out ne '' && $out ne '(null)' && $out =~ /^\d+$/;
#     }
#     return (1, $size, 0);
# }
#
# sub _resolve_relative {
#     my ($rel, $roots) = @_;
#     return undef unless defined $rel && defined $roots && ref($roots) eq 'ARRAY';
#     for my $root (@$roots) {
#         next unless defined $root && length $root;
#         my $cand = ($root =~ m{/$}) ? ($root . $rel) : ("$root/$rel");
#         return $cand if -e $cand || -l $cand;
#     }
#     return undef;
# }



# Detect non-ASCII and return placeholder translation
sub maybe_translate {
    my ($text) = @_;
    return "" unless defined $text && $text ne "";

    # Quick ASCII check
    if ($text =~ /^[\x00-\x7F]+$/) {
        return $text;  # already plain ASCII
    }

    # Placeholder: actual translation API/DLL goes here
    return "[TODO: translate] $text";
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

        Logger::info("[CACHE] Wrote '$type' cache ($record_count entries) -> $cache_file");
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
