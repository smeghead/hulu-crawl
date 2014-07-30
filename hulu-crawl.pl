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
use JSON qw/decode_json/;
use URI;
use Web::Scraper;

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

my $get_token_command = $FindBin::Bin . '/hulu-gettoken.py';
my $access_token = `$get_token_command`;
my $api_url = 'http://www.hulu.jp/mozart/v1.h2o/<apiname>?caption=&country=&decade=&exclude_hulu_content=1&genre=&language=&sort=popular_all_time&_language=ja&_region=jp&items_per_page=32&position=<position>&_user_pgid=24&_content_pgid=24&_device_id=1&region=jp&locale=ja&language=ja&access_token=' . $access_token;
# http://www.hulu.jp/mozart/v1.h2o/shows?caption=&country=&decade=&exclude_hulu_content=1&genre=&language=&sort=popular_all_time&_language=ja&_region=jp&items_per_page=32&position=0&_user_pgid=24&_content_pgid=24&_device_id=1&region=jp&locale=ja&language=ja&access_token=u3hqs8d3aJqRiJZYU5nrD7CQJ58%3DGOzf8jSX05783024639399a26480b69cb945a5e5e24f6d5f35514b01c1cb3e812225d701bdcf37da422873cc1343140751481749

my @expire_urls = qw{
    http://www.hulu.jp/support/article/26284950
    http://www.hulu.jp/support/article/25746809
    http://www.hulu.jp/support/article/25746829
    http://www.hulu.jp/support/article/26284970
    http://www.hulu.jp/support/article/25746859
    http://www.hulu.jp/support/article/26284990
    http://www.hulu.jp/support/article/25746869
    http://www.hulu.jp/support/article/25829844
    http://www.hulu.jp/support/article/25829854
    http://www.hulu.jp/support/article/25829864
};

my %opts = ();
getopts('p:', \%opts);

my $checked_date = DateTime->now->epoch;

sub parse_videos {
    my ($content) = @_;

    my $data = decode_json($content);
    my @videos = ();
    foreach my $video (@{$data->{data}}) {
        my $show = $video->{show};
        $logger->debug(encode_utf8($show->{name}));
        push @videos, +{
            url => 'http://www2.hulu.jp/' . $show->{canonical_name},
            title => $show->{name},
            seasons => $show->{seasons_count} || 1,
            episodes => $show->{videos_count} || 1,
        };
    }
    return @videos;
}

sub exists_check {
    my ($vs, $adds) = @_;
    
    my @new_videos = ();
    V: for my $nv (@$adds) {
        for my $v (@$vs) {
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
        ssl => 1,
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
        print "it may deleted? $id: ", $row->{title}, " checking...\n";
        next unless deleted_video($row);

        print "it has deleted $id: ", $row->{title}, "\n";

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

sub date_format {
    my ($s) = @_;

    my ($y, $m, $d) = $s =~ m{(\d+)年(\d+)月(\d+)日};
    return sprintf("%04d年%02d月%02d日", $y, $m, $d);
}

sub expired_videos {
    my ($dbh, $checked_date, $last_checked_date) = @_;
 
    my $nt = Net::Twitter->new(
        traits   => [qw/OAuth API::RESTv1_1/],
        consumer_key => $config->param('consumer_key'),
        consumer_secret => $config->param('consumer_secret'),
        access_token => $config->param('access_token'),
        access_token_secret => $config->param('access_token_secret'),
        ssl => 1,
    );

    my $videos = $nt->search({
        q => '#hulu_配信期限',
        locale => 'ja',
        count => 100,
        result_type => 'mixed',
    });
    my @expires = ();
    foreach my $v (@{$videos->{statuses}}) {
        $logger->debug(encode_utf8($v->{text}));
        $logger->debug(encode_utf8($v->{user}->{screen_name}));
        next unless $v->{user}->{screen_name} eq 'Hulu_JPSupport';

        my $text = $v->{text};

        $logger->debug(encode_utf8($text));
        my ($title, $seasons, $url, $year, $month, $day) = $text =~ m{「(.*)」(.*)?をHuluで配信しております。(.*) 配信.*は(\d+)年(\d+)月(\d+)日の23時までとなります 。};

        $logger->debug(encode_utf8($title));
        next unless $title;

        $logger->debug(encode_utf8($title));
        my $now = DateTime->now();
        $logger->debug(encode_utf8($now->strftime('%Y-%m-%d')));
        my $date = sprintf('%04d-%02d-%02d',
            $year,
            $month,
            $day);
        $logger->debug(encode_utf8($date));
        push @expires, {
            title => $title,
            seasons => $seasons,
            expire => $date,
            url => $url,
        };

    }

    my $sth_delete = $dbh->prepare(q{
        delete from expires where checked_date = ? and title = ? and seasons = ?
    });

    my $sth = $dbh->prepare(q{
        insert into expires (checked_date, title, seasons, expire, url, created_at, updated_at) values (?, ?, ?, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))
    });
    foreach my $v (@expires) {
        $sth_delete->execute($checked_date, $v->{title}, $v->{seasons});
        $sth->execute($checked_date, $v->{title}, $v->{seasons}, $v->{expire}, $v->{url});
    }
    $logger->debug('checked_date:' . $checked_date . ' last_checked_date:' . $last_checked_date);
    my $rows = $dbh->selectall_arrayref(q{
        select * from expires as new
        where new.checked_date = ?
          and not exists (
            select * from expires as old
            where old.checked_date = ?
              and old.title || old.seasons || old.expire = new.title || new.seasons || new.expire
          )
    }, {Slice => {}}, $checked_date, $last_checked_date);
    my $i = 0;
    for my $r (@$rows) {
        $logger->debug(encode_utf8('expired update. ' . decode_utf8($r->{title})));
        if ($i > 10) {
            my $message = 
                '配信期限が更新されました。その他多数あります。詳しくは http://hulu-update.info/expired.html で確認して下さい。'; 
            twitter_post($message);
            last;
        }
        my $message = 
            '配信期限が更新されました。[' . decode_utf8($r->{title}) . '] ' . decode_utf8($r->{seasons}) . ' ' . decode_utf8($r->{expire}) . ' http://hulu-update.info/expired.html' ;
        twitter_post($message);

        $i++;
    }

    print 'expired_videos.ok', "\n";
}

sub record_video_count {
    my ($dbh) = @_;

    my $sth = $dbh->prepare(q{
        select count(*) as count
        from videos as v
        where v.updated_at > date('now' , '-1 days' )
          and v.episodes > 0
    });
    $sth->execute;
    my $row = $sth->fetchrow_hashref() or die('failed to fetch count.');
    my $count = $row->{count};
    print 'video count: ', $count, "\n";

    my $today = DateTime->today(time_zone => 'local')->strftime('%Y-%m-%d');
    print 'today: ', $today, "\n";

    $sth = $dbh->prepare(q{delete from video_counts where date = ?});
    $sth->execute($today);

    $sth = $dbh->prepare(q{insert into video_counts (date, count) values (?, ?)});
    $sth->execute(
        $today,
        $count,
    ) or die 'failed to insert.';
    print 'recorded count.ok', "\n";
}

sub get_paged_api_url {
    my ($apiname, $p) = @_;
    my $position = $p * 32;
    my $api = $api_url;
    $api =~ s/<apiname>/$apiname/;
    $api =~ s/<position>/$position/;
    return $api;
}

try {
    my @videos = ();
    $logger->debug('dramas');
    for my $p (0 .. 100) {
        $logger->debug('page:' . $p);
        my $content = LWP::UserAgent->new->request(HTTP::Request->new(GET => get_paged_api_url('shows', $p)))->content;
        my @adds = parse_videos($content);
        @adds = exists_check(\@videos, \@adds);
        last unless scalar @adds;

        push @videos, @adds;
    }
    $logger->debug('movies');
    for my $p (0 .. 100) {
        $logger->debug('page:' . $p);
        my $content = LWP::UserAgent->new->request(HTTP::Request->new(GET => get_paged_api_url('movies', $p)))->content;
        my @adds = parse_videos($content);
        @adds = exists_check(\@videos, \@adds);
        last unless scalar @adds;

        push @videos, @adds;
    }
    $logger->debug('videos count:' . scalar @videos);
    die 'no videos. crawl failed.' unless scalar @videos;

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
                my $increace = $old->{episodes} < $v->{episodes} ? '↑↑↑' : '↓↓↓';
                my $message = 
                    '[' . $v->{title} . '] が更新されました。' .
                    $old->{seasons} . '(' . $old->{episodes} . ') -> ' . $v->{seasons} . '(' . $v->{episodes} . ') ' . $increace . ' ' . $v->{url};
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
    #check deleted videos
    check_deleted_videos($dbh, $last_checked_date, $checked_date);

    record_video_count($dbh);

    expired_videos($dbh, $checked_date, $last_checked_date);

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
system($FindBin::Bin . '/hulu-website.pl');
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create index videos_url on videos(url);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table published_videos (id integer primary key, checked_date varchar, video_id integer, created_at datetime, updated_at datetime);
create index published_videos_checked_date on published_videos(checked_date);
create table video_counts (id integer primary key, date varchar not null, count integer);
create table expires (id integer primary key, checked_date varchar, title varchar,
seasons integer, expire varchar, url varchar, created_at datetime, updated_at datetime);

