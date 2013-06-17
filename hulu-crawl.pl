#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use LWP;
use Encode;
use Net::Twitter;
use Data::Dumper;
use FindBin;
use Try::Tiny;
use Getopt::Std;
use List::Compare;
use Config::Simple;

use Log::Log4perl;
my $config = new Config::Simple($FindBin::Bin . '/twitter.conf');

my $logfile = $FindBin::Bin . '/hulu-crawl.log';
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

my $api_url = 'http://www2.hulu.jp/content?country=all&genre=all&type_group=all&ajax=true&page=';

my %opts = ();
getopts('p:', \%opts);

my $checked_date = DateTime->now->epoch;

sub parse_videos {
    my ($content) = @_;

    $content =~ s{\A.*\$\("\#show-results-list"\)\.replaceWith\("(.*)"\);.*\z}{$1}xms;
    $content =~ s{\\}{}g;
    return grep {$_} map {
        my ($url, $title) = $_ =~ m{
            show-title-container .*
            href="([^"]+)" .*
            class="bold-link[^"]*">([^<]+)</a> .*
        }mxs;
        my ($seasons, $episodes) = $_ =~ m{
            digit'>(\d+)< .*
            digit'>(\d+)< .*
        }mxs;
        $title ?
            +{
                url => $url,
                title => $title,
                seasons => $seasons || 1,
                episodes => $episodes || 1,
            } : undef;
    } split /<\\?\/td>/, $content;
}

sub exists_check {
    my ($vs, $adds) = @_;
    
    my @new_videos = ();
    V: for my $nv (@$adds) {
        for my $v (@$vs) {
#            print 'exists ' . encode_utf8($v->{url}) . "\n" if $v->{url} eq $nv->{url};
            next V if $v->{url} eq $nv->{url};
        }
        push @new_videos, $nv;
    }
    return @new_videos;
}

sub twitter_post {
    my ($message) = @_;

    $message .= ' http://hulu-update.info/';
    $logger->info(encode_utf8($message));
    my $nt = Net::Twitter->new(
        traits   => [qw/OAuth API::RESTv1_1/],
        consumer_key => $config->param('consumer_key'),
        consumer_secret => $config->param('consumer_secret'),
        access_token => $config->param('access_token'),
        access_token_secret => $config->param('access_token_secret'),
    );

    if (defined $opts{p} && $opts{p} eq 'true') {
        $nt->update($message) or die $@;
    } else {
        $logger->debug('not post.');
    }
}

sub last_checked_date {
    my ($dbh) = @_;
    my $rows = $dbh->do('');
    my $sth = $dbh->prepare(q{select max(checked_date) as last_checked_date from published_videos});
    $sth->execute or die 'failed to select. url';
    return $sth->fetchrow_hashref->{last_checked_date};
}

sub deleted_video {
    my ($row) = @_;

    my $response = LWP::UserAgent->new->request(HTTP::Request->new(GET => $row->{url}));
    return $response->status_line =~ m{404};
}

sub check_deleted_videos {
    my ($dbh, $last_checked_date, $checked_date) = @_;
    my $rows = $dbh->selectall_arrayref(q{
        select v.id
        from published_videos as p
        inner join videos as v on v.id = p.video_id
        where p.checked_date = ?
    }, {Slice => {}}, $last_checked_date);
    my @last_videos = ();
    for my $r (@$rows) {
        push @last_videos, $r->{id};
    }
    $rows = $dbh->selectall_arrayref(q{
        select v.id
        from published_videos as p
        inner join videos as v on v.id = p.video_id
        where p.checked_date = ?
    }, {Slice => {}}, $checked_date);
    my @new_videos = ();
    for my $r (@$rows) {
        push @new_videos, $r->{id};
    }
    print 'last_videos: ', scalar @last_videos, "\n";
    print 'new_videos: ', scalar @new_videos, "\n";

    my $lc = List::Compare->new(\@last_videos, \@new_videos);
    for my $id ($lc->get_Lonly) {
        my $row = $dbh->selectrow_hashref(q{
            select * from videos where id = ?
        }, {Slice => {}}, $id);
        print "deleted $id: ", $row->{title}, "\n";
        next unless deleted_video($row);

        my $sth = $dbh->prepare(q{insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 0, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
        $sth->execute(
            $id,
            0,
            0,
        ) or die 'failed to insert. id:' . $id;
        $sth = $dbh->prepare(q{update videos set seasons = ?, episodes = ?, updated_at = datetime('now', 'localtime') where id = ?});
        $sth->execute(
            0,
            0,
            $id,
        ) or die 'failed to update. id:' . $id;
        my $message = '[' . decode_utf8($row->{title}) . '] が削除されました。' . $row->{url};
        $logger->info(encode_utf8($message));
        twitter_post($message);
    }
}

try {
    my @videos = ();
    for my $p (1 .. 100) {
        $logger->debug('page:' . $p);
        my $content = LWP::UserAgent->new->request(HTTP::Request->new(GET => $api_url . $p))->content;
        $content = decode_utf8($content);
        my @adds = parse_videos($content);
        @adds = exists_check(\@videos, \@adds);
        last unless scalar @adds;

        push @videos, @adds;
    }

    use DBI;
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 1});

    my $last_checked_date = last_checked_date($dbh);
    print 'last_checked_date:', $last_checked_date, "\n";
    print 'checked_date:', $checked_date, "\n";

    my $count = scalar @videos;
    my $i = 1;
    for my $v (@videos) {
        $logger->debug("($i/$count) " . $v->{url});
        $i++;
        my $select = "select * from videos where url = ?";
        my $sth = $dbh->prepare($select);
        my $video_id;
        $sth->execute($v->{url});
        if (my $old = $sth->fetchrow_hashref) {
            if ($old->{seasons} != $v->{seasons} or $old->{episodes} != $v->{episodes}) {
                $logger->info('changed.');
                my $message = 
                    '[' . $v->{title} . '] が更新されました。' .
                    $old->{seasons} . '(' . $old->{episodes} . ') -> ' . $v->{seasons} . '(' . $v->{episodes} . ') ' . $v->{url};
                twitter_post($message);
                $sth = $dbh->prepare(q{insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 0, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
                $sth->execute(
                    $old->{id},
                    $v->{seasons},
                    $v->{episodes},
                ) or die 'failed to insert. url:' . $v->{title};
            }
            $sth = $dbh->prepare(q{update videos set seasons = ?, episodes = ?, updated_at = datetime('now', 'localtime') where id = ?});
            $sth->execute(
                $v->{seasons},
                $v->{episodes},
                $old->{id},
            ) or die 'failed to update. url:' . $v->{title};
            $video_id = $old->{id};
        } else {
            my $seasons_info = '';
            if ($v->{episodes} > 1) {
                $seasons_info = "$v->{seasons} ($v->{episodes})";
            }
            my $message = '[' . $v->{title} . '] が追加されました。' . $seasons_info . ' ' . $v->{url};
            twitter_post($message);
            $sth = $dbh->prepare(q{insert into videos (url, title, seasons, episodes, created_at, updated_at) values (?, ?, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
            $sth->execute(
                $v->{url},
                $v->{title},
                $v->{seasons},
                $v->{episodes},
            ) or die 'failed to insert. url:' . $v->{title};
            my $last_insert_id = $dbh->func('last_insert_rowid');
            print 'new id:' . $last_insert_id, "\n";
            $sth = $dbh->prepare(q{insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 1, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
            $sth->execute(
                $last_insert_id,
                $v->{seasons},
                $v->{episodes},
            ) or die 'failed to insert. url:' . $v->{title};
            $video_id = $last_insert_id;
        }
        $sth = $dbh->prepare(q{insert into published_videos (video_id, checked_date, created_at, updated_at) values (?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
        $sth->execute(
            $video_id,
            $checked_date,
        ) or die 'failed to insert. id:' . $video_id;
    }
    # check deleted videos
    check_deleted_videos($dbh, $last_checked_date, $checked_date);

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create index videos_url on videos(url);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table published_videos (id integer primary key, checked_date varchar, video_id integer, created_at datetime, updated_at datetime);
create index published_videos_checked_date on published_videos(checked_date);

