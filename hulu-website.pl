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
use Text::MediawikiFormat qw(wikiformat);
use XML::FeedPP;
use DateTime::Format::W3CDTF;
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
        "$base_url/hulu.png",
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
    my ($latest_videos, $all_videos) = @_;

    my $tx = Text::Xslate->new(path => $FindBin::Bin);

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

sub create_search_page {
    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    my $data = {
    };
    mkdir $FindBin::Bin . '/website';
    my $content = $tx->render('website-template/search.tx.html', $data);
    my $out_file = $FindBin::Bin . '/website/search.html';
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
    my ($dbh, $all_videos) = @_;

    my $tx = Text::Xslate->new(path => $FindBin::Bin);

    for my $video (@$all_videos) {
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

        # wikipedia
        $sth = $dbh->prepare(q{
            select * from wikipedias
            where video_id = ?
        });
        $sth->execute($video->{id});

        my $entry = $sth->fetchrow_hashref;
        die $sth->errstr if $sth->err;

        if ($entry && $entry->{content}) {
            $entry->{content} = decode_utf8($entry->{content});
            $entry->{content} =~ s/<\/?ref[^>]*>//msg;
            $entry->{content} =~ s/\{\{.*?\}\}//msg;
            $entry->{content} =~ s/(\{\|.*?\|\})/table_format($1)/emsg; # TODO: Text::MediawikiFormat がテーブルに対応してないため、現時点の対応としては、削除している。
            $entry->{content} = wikiformat($entry->{content});
        };

        my $data = {
            video => $video,
            histories => \@histories,
            entry => $entry,
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
        where v.updated_at > date('now' , '-1 days' )
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

    create_rss(\@latest_videos);
    create_index_page(\@latest_videos, \@all_videos);
    create_search_page;

    create_video_pages($dbh, \@all_videos);

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);

