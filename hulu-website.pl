#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Encode;
use Data::Dumper;
use FindBin;
use Try::Tiny;
use Getopt::Std;
use Text::Xslate;
use File::Copy::Recursive qw(rcopy);

use Log::Log4perl;

my $logfile = $FindBin::Bin . '/hulu-website.log';
my $conf = qq(
    log4perl.logger.main          = DEBUG, Logfile, Screen

    log4perl.appender.Logfile          = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename = $logfile
    log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.ConversionPattern = [%d] %F %L %m%n

    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
);
Log::Log4perl->init(\$conf);
my $logger = Log::Log4perl->get_logger('main');

my %opts = ();
getopts('p:', \%opts);

sub create_static_files {
    my $out_dir = $FindBin::Bin . '/website';
    mkdir $out_dir;

    my @dirs = qw(css js img);
    for my $d (@dirs) {
        rcopy $FindBin::Bin . "/website-template/$d", "$out_dir/$d";
    }
}

sub create_index_page {
    my ($latest_videos, $all_videos) = @_;

    my $tx = Text::Xslate->new();

    my $data = {
        latest_videos => $latest_videos,
        all_videos => $all_videos,
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/index.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/index.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub create_video_pages {
    my ($dbh, $all_videos) = @_;

    my $tx = Text::Xslate->new();

    for my $video (@$all_videos) {
        my $sth = $dbh->prepare(q{
            select u.* from updates as u
            where u.video_id = ?
            order by u.updated_at
        });
        $sth->execute($video->{id});

        my @histories = ();
        while (my $row = $sth->fetchrow_hashref()){
            push @histories, $row;
        }
        die $sth->errstr if $sth->err;

        my $data = {
            video => $video,
            histories => \@histories,
        };
        mkdir $FindBin::Bin . '/website/video';
        my $content = $tx->render('website-template/video/video.tx.html', $data);
        my $out_file = $FindBin::Bin . "/website/video/$video->{path}.html";
        open my $out_fh, ">", $out_file
            or die "Cannot open $out_file for write: $!";
        print $out_fh encode_utf8($content);
        close $out_fh;
    }
}

try {
    use DBI;
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 1});

    # latest_videos
    my $sth = $dbh->prepare(q{
        select u.*, v.title, v.url from updates as u
        inner join videos as v on v.id = u.video_id
        order by u.created_at desc
        limit 20
    });
    $sth->execute;

    my @latest_videos = ();
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        push @latest_videos, $row;
    }
    die $sth->errstr if $sth->err;

    # all_videos
    $sth = $dbh->prepare(q{
        select v.* from videos as v
        where v.created_at > date('now' , '-1 days' )
        order by v.title
    });
    $sth->execute;

    my @all_videos = ();
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        push @all_videos, $row;
    }
    die $sth->errstr if $sth->err;
    print scalar @all_videos;

    create_static_files;

    create_index_page(\@latest_videos, \@all_videos);

    create_video_pages($dbh, \@all_videos);

#     for my $v (@videos) {
#         $logger->debug($v->{url});
#         my $select = "select * from videos where url = ?";
#         my $sth = $dbh->prepare($select);
#         $sth->execute($v->{url});
#         if (my $old = $sth->fetchrow_hashref) {
#             if ($old->{seasons} != $v->{seasons} or $old->{episodes} != $v->{episodes}) {
#                 $logger->info('changed.');
#                 my $message = 
#                     '[' . $v->{title} . '] が更新されました。' .
#                     $old->{seasons} . '(' . $old->{episodes} . ') -> ' . $v->{seasons} . '(' . $v->{episodes} . ') ' . $v->{url};
#                 twitter_post($message);
#                 $sth = $dbh->prepare('insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 0, ?, ?, current_timestamp, current_timestamp)');
#                 $sth->execute(
#                     $old->{id},
#                     $v->{seasons},
#                     $v->{episodes},
#                 ) or die 'failed to insert. url:' . $v->{title};
#             }
#             $sth = $dbh->prepare('update videos set seasons = ?, episodes = ?, updated_at = current_timestamp where id = ?');
#             $sth->execute(
#                 $v->{seasons},
#                 $v->{episodes},
#                 $old->{id},
#             ) or die 'failed to update. url:' . $v->{title};
#         } else {
#             my $message = '[' . $v->{title} . '] が追加されました。' . $v->{url};
#             twitter_post($message);
#             $sth = $dbh->prepare('insert into videos (url, title, seasons, episodes, created_at, updated_at) values (?, ?, ?, ?, current_timestamp, current_timestamp)');
#             $sth->execute(
#                 $v->{url},
#                 $v->{title},
#                 $v->{seasons},
#                 $v->{episodes},
#             ) or die 'failed to insert. url:' . $v->{title};
#             my $last_insert_id = $dbh->func('last_insert_rowid');
#             print 'new id:' . $last_insert_id, "\n";
#             $sth = $dbh->prepare('insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 1, ?, ?, current_timestamp, current_timestamp)');
#             $sth->execute(
#                 $last_insert_id,
#                 $v->{seasons},
#                 $v->{episodes},
#             ) or die 'failed to insert. url:' . $v->{title};
#         }
#     }

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);

