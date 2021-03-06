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
use XML::FeedPP;
use DateTime::Format::W3CDTF;
use DateTime::Format::Strptime;
use URI::Escape;
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

    my @dirs = qw(css js img favicon.ico);
    for my $d (@dirs) {
        rcopy $FindBin::Bin . "/website-template/$d", "$out_dir/$d";
    }
}

sub last_checked_date {
    my ($dbh) = @_;
    my $rows = $dbh->do('');
    my $sth = $dbh->prepare(q{select max(checked_date) as last_checked_date from published_videos});
    $sth->execute or die 'failed to select. url';
    return $sth->fetchrow_hashref->{last_checked_date};
}

sub create_rss {
    my ($latest_videos) = @_;

    my $rss = XML::FeedPP::RSS->new;
    my $appname = 'hulu.jp 更新情報';
    my $base_url = 'http://hulu-update.info/';
    my $description = 'hulu.jpの更新情報を纏める非公式サイトです。 huluの動画に変更があるかどうかを1時間おきにチェックして、変更があれば更新されます。 最新情報に掲載される情報は、twitter の @hulu_jp_bot と同じ情報です。';
    $rss->language('ja-JP');
    $rss->title($appname);
    $rss->link($base_url);
    $rss->description($description);
    $rss->pubDate(DateTime::Format::W3CDTF->format_datetime(DateTime->now(time_zone => 'local')));
    $rss->image(
        "${base_url}img/hulu.png",
        $appname,
        $base_url,
        $description,
    );

    for my $v (@$latest_videos) {
        my $title = decode_utf8($v->{title});
        $rss->add_item(
          title       => $title,
          link        => "http://hulu-update.info/video/$v->{path}.html",
          description => "$title が" . ($v->{episodes} == 0 ? '削除' : $v->{is_new} ? '追加' : '更新') . 'されました。',
        );
    }
    mkdir $FindBin::Bin . '/website';
    $rss->to_file($FindBin::Bin . '/website/rss.xml');
}

sub create_index_page {
    my ($latest_videos, $counts, $ranking_videos) = @_;

    my $tx = Text::Xslate->new(
        path => $FindBin::Bin,
        module => ['Text::Xslate::Bridge::Star'],
    );

    my $data = {
        latest_videos => $latest_videos,
        counts => $counts,
        ranking_videos => $ranking_videos,
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/index.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/index.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub create_list_page {
    my ($all_videos, $ranking_videos) = @_;

    my $tx = Text::Xslate->new(
        path => $FindBin::Bin,
        module => ['Text::Xslate::Bridge::Star'],
    );

    my $data = {
        all_videos => $all_videos,
        ranking_videos => $ranking_videos,
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/list.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/list.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub create_expired_page {
    my ($expired_videos) = @_;

    my $tx = Text::Xslate->new(
        path => $FindBin::Bin,
        module => ['Text::Xslate::Bridge::Star'],
    );

    my $data = {
        expired_videos => $expired_videos,
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/expired.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/expired.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub create_static_page {
    my ($name) = @_;
    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    my $data = {
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render("website-template/$name.tx.html", $data);
    my $out_file = $FindBin::Bin . "/website/$name.html";
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub create_recommend_page {
    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    my $data = {
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/recommend.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/recommend.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

sub table_format {
    my ($text) = @_;
    my $table = {attr => '', rows => []};
    my @lines = split "\n", $text;

    my $row = [];
    for my $line (@lines) {
       if ($line =~ m(^{\|)) {
            #start
            $line =~ s(^{\|)();
            $table->{attr} = $line;
        } elsif ($line =~ m(^\s*[\|!][^\+\-}])) {
            #col
            $line =~ s(^\s*[\|!]\s*)();
            my $th = $line =~ m{!};
            my @cols = split /\s*[\|!]{2}\s*/, $line;
            for my $col (@cols) {
                my ($attr, $val) = ('', $col);
                my $pos = index($col, '|');
                if ($pos > -1) {
                    $attr = substr($col, 0, $pos);
                    $val = substr($col, $pos + 1);
                }

                if ($th) {
                    push @$row, {th => {attr => $attr, value => $val}};
                } else {
                    push @$row, {td => {attr => $attr, value => $val}};
                }
            }
        } elsif ($line =~ m(^\s*\|\-)) {
            #end row
            push @{$table->{rows}}, $row;
            $row = [];
        } elsif ($line =~ m(\|})) {
            #end table
            push @{$table->{rows}}, $row;
            $row = [];
        }
    }
    my $table_str = "<table $table->{attr}>\n";
    for my $row (@{$table->{rows}}) {
        $table_str .= "  <tr>\n";
        for my $col (@$row) {
            my @keys = keys %$col;
            my $key = $keys[0];
            $table_str .= "    <$key $col->{$key}->{attr}>$col->{$key}->{value}</$key>\n";
        }
        $table_str .= "  </tr>\n";
    }
    $table_str .= "</table>\n";
    return $table_str;
}

sub create_video_pages {
    my ($dbh) = @_;

    # all_videos
    my $sth = $dbh->prepare(q{
        select v.* from videos as v
        where v.updated_at > date('now' , '-1 days' )
        order by v.title
    });
    $sth->execute;

    my @all_videos = ();
    my $last_index = '';
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        my $index = substr $row->{title}, 0, 1;
        if ($index ne $last_index) {
            $row->{index} = $index;
            $last_index = $index;
        }
        push @all_videos, $row;
    }
    die $sth->errstr if $sth->err;

    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    for my $video (@all_videos) {
        # histories
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

sub create_all_video_list_pages {
    my ($dbh, $ranking_videos) = @_;

    # all_videos
    my $sth = $dbh->prepare(q{
        select v.* from videos as v
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

    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    my $data = {
        all_videos => \@all_videos,
        ranking_videos => $ranking_videos,
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/all.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/all.html';
    open my $out_fh, ">", $out_file
        or die "Cannot open $out_file for write: $!";
    print $out_fh encode_utf8($content);
    close $out_fh;
}

try {
    use DBI;
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 1});

    # expired_videos
    my $sth = $dbh->prepare(q{
        select max(id), title, seasons, expire, url
        from expires
        where expire > current_timestamp
        group by title, seasons, expire, url
        order by expire
    });
    $sth->execute();

    my @expired_videos = ();
    my $now = DateTime->now();
    my $parser = DateTime::Format::Strptime->new(pattern=>"%Y-%m-%d");
    while (my $row = $sth->fetchrow_hashref()){
        my $d = $parser->parse_datetime($row->{expire});
        my $duration = $d - $now;
        my ($months, $days) = $duration->in_units('months', 'days');
        $row->{days} = $months * 30 + $days + 1;
        push @expired_videos, $row;
    }
    die $sth->errstr if $sth->err;

    # latest_videos
    my $sth = $dbh->prepare(q{
        select u.*, v.title, v.url from updates as u
        inner join videos as v on v.id = u.video_id
        where u.created_at > date('now', '-3 days', 'localtime')
        order by u.created_at desc
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
        where v.updated_at > date('now' , '-1 days' )
          and v.episodes > 0
        order by v.title
    });
    $sth->execute;

    my @all_videos = ();
    my $last_index = '';
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        my $index = substr $row->{title}, 0, 1;
        if ($index ne $last_index) {
            $row->{index} = $index;
            $last_index = $index;
        }
        push @all_videos, $row;
    }
    die $sth->errstr if $sth->err;
    print scalar @all_videos;

    # video_count
    $sth = $dbh->prepare(q{
        select * from video_counts
        where date > date('now', '-1 year')
        order by date
    });
    $sth->execute;
    my @counts = ();
    while (my $row = $sth->fetchrow_hashref()) {
        push @counts, $row;
    }

    die $sth->errstr if $sth->err;
    print Dumper(\@counts);

    my @lanking_urls = `grep 'GET /video/[^ ]\\+\\.html' /var/log/nginx/hulu-update.info.access.log | awk '{videos[\$7]++}END{for (key in videos) {print videos[key] " " key}}' | sort -t" " -n -r | head -10 | sed -e 's/[0-9]\\+ //'`;
    my @ranking_videos = ();
    foreach my $url (@lanking_urls) {
        chomp $url;
        $url = uri_unescape($url);
        $url =~ s/\.html//;
        $url =~ s/\/video//;
        $url =~ s/\t.*//;
        print 'url:', $url, "\n";
        $sth = $dbh->prepare(q{
            select v.* from videos as v
            where v.url like '%' || ? || '%'
            order by v.title
        });
        $sth->execute($url);
        my $row = $sth->fetchrow_hashref() or die 'failed to fetch.';
        die $sth->errstr if $sth->err;
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        push @ranking_videos, $row;
    }

    create_static_files;

    create_rss(\@latest_videos);
    create_index_page(\@latest_videos, \@counts, \@ranking_videos);
    create_list_page(\@all_videos, \@ranking_videos);
    create_expired_page(\@expired_videos);
    create_static_page('search');
    create_static_page('recommend');
    create_static_page('about');

    create_video_pages($dbh);
    create_all_video_list_pages($dbh, \@ranking_videos);

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);

