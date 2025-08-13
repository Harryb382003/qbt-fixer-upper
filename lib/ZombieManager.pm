package ZombieManager;

use common::Sense;
use File::Path qw(make_path);
use File::Spec;
use File::Slurp;
use JSON;
use POSIX qw(strftime);
use feature qw(say);

use lib 'lib';
use Utils;
use Logger;
use Exporter 'import';
use TorrentParser qw(match_by_date); # now importing from TorrentParser

our @EXPORT_OK = qw(
    write_cache
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        qb                   => $args{qb},
        heal_candidates      => {},
        disposal_candidates  => {},
    };
    bless $self, $class;
    return $self;
}

sub match_by_date {
    my ($self, $wiggle_minutes, $opts) = @_;
    $wiggle_minutes ||= 10;

    my $zombies_ref = $self->{zombies} || {};
    return unless %$zombies_ref;

    # Pull mdls metadata for all zombie source paths
    my $zombie_mdls = Utils::get_mdls($zombies_ref);

    my @matches;
    my @no_added_on;
    my @no_save_path;

    foreach my $zombie_id (keys %$zombies_ref) {
        my $zombie    = $zombies_ref->{$zombie_id};
        my $name      = $zombie->{name}       // 'UNKNOWN';
        my $path      = $zombie->{save_path}  // 'UNKNOWN PATH';
        my $added_on  = $zombie->{added_on};

        say "$name ($path)";

        unless ($added_on) {
            push @no_added_on, $zombie;
            next;
        }

        # mdls info for this torrent file
        my $source_path = $zombie->{source_path} // '';
        my $mdls_info   = $zombie_mdls->{$source_path} || {};
        my $created     = $mdls_info->{kMDItemFSCreationDate} // '';
        my $added       = $mdls_info->{kMDItemDateAdded}      // '';

        my $matched = 0;
        if ($added && abs(str2epoch($added) - $added_on) <= ($wiggle_minutes * 60)) {
            say "    match (added)";
            $matched++;
        }
        if ($created && abs(str2epoch($created) - $added_on) <= ($wiggle_minutes * 60)) {
            say "    match (creation)";
            $matched++;
        }

        if ($matched) {
            push @matches, $zombie;
        } else {
            push @no_save_path, $zombie;
        }
    }

    Logger::info("[MATCH] $wiggle_minutes minute window — "
        . scalar(@matches) . " matches, "
        . scalar(@no_added_on) . " with no added_on, "
        . scalar(@no_save_path) . " with no save_path match");

    return {
        matches            => \@matches,
        no_added_on        => \@no_added_on,
        no_save_path       => \@no_save_path,
        matches_count      => scalar(@matches),
        no_added_on_count  => scalar(@no_added_on),
        no_save_path_count => scalar(@no_save_path),
    };
}


sub str2epoch {
    my $str = shift;
    $str =~ s/\+0000//;  # strip UTC offset if present
    chomp(my $epoch = `date -j -f "%Y-%m-%d %H:%M:%S" "$str" "+%s" 2>/dev/null`);
    return $epoch || 0;
}


# ... other methods unchanged ...

# # Delegating stub
# sub match_by_date {
#     my ($self, @args) = @_;
#     return TorrentParser::match_by_date($self, @args);
# }

1;


# I don't know what the fuck
