#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use WWW::Wikipedia;
use Encode;
use Data::Dumper;
use FindBin;
use Try::Tiny;
use Getopt::Std;

use Log::Log4perl;

my $logfile = $FindBin::Bin . '/hulu-wikipedia.log';
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

# my $api_url = 'http://www2.hulu.jp/content?country=all&genre=%E3%83%89%E3%83%A9%E3%83%9E&type_group=all&ajax=true&page=';
my $api_url = 'http://www2.hulu.jp/content?country=all&genre=all&type_group=all&ajax=true&page=';

my %opts = ();
getopts('t:q:n:', \%opts);

sub convert_title {
    my ($title) = @_;

    $title = decode_utf8($title);
    $title =~ tr{１２３４５６７８９０／：～}{1234567890/:〜};
    $title =~ s{™}{}g;
    return $title;
}

#print convert_title('CSI：恐竜科学捜査班'), "\n";
#print convert_title('アラド戦記 ～スラップアップパーティー～'), "\n";
#print convert_title('９デイズ'), "\n";
#print convert_title('スパイダーマン™'), "\n";
#print convert_title('HEROES／ヒーローズ'), "\n";
#die;

sub get_wikipedia_contents {
    my ($dbh, $all_videos) = @_;

    my $wiki = WWW::Wikipedia->new(language => 'ja');
    for my $v (@$all_videos) {
        my $title = convert_title($v->{title});
        $logger->debug('converted:' . encode_utf8($title));
        my $entry = $wiki->search($title);

        $logger->debug($entry->title) if $entry;

        my $sth = $dbh->prepare(q{insert into wikipedias (video_id, title, content, created_at, updated_at) values (?, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
        $sth->execute(
            $v->{id},
            $entry ? $entry->title : '',
            $entry ? $entry->fulltext_basic : '',
        ) or die 'failed to insert. url:' . $v->{url};
    }
}

sub get_videos {
    my ($dbh, $limit, $q) = @_;
    # all_videos
    my $sth = $dbh->prepare(q{
        select v.* from videos as v
        left join wikipedias as w on w.video_id = v.id
        where w.id is null and v.title like '%' || ? || '%'
        order by v.updated_at desc
        limit ?
    });
    $sth->execute($q, $limit);

    my @all_videos = ();
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        push @all_videos, $row;
    }
    die $sth->errstr if $sth->err;
    return \@all_videos;
}

sub get_wikipedia {
    my ($dbh, $title, $q) = @_;
    # all_videos
    my $sth = $dbh->prepare(q{
        select w.* from wikipedias as w
        inner join videos as v on v.id = w.video_id
        where v.title = ?
    });
    $logger->debug(encode_utf8($title));
    $sth->execute($title);

    my @all_videos = ();
    my $row = $sth->fetchrow_hashref();
    die $sth->errstr if $sth->err;
    return $row;
}

try {
    use DBI;
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 1});

    if (defined $opts{t}) {
        my $title = decode_utf8($opts{t});
        my $q = decode_utf8($opts{q}) or die 'requrired q option.';

        my $wikipedia = get_wikipedia($dbh, $title, $q) or die 'no video or wikipedia.';
        
        die 'content already exist.' if $wikipedia->{content};

        my $wiki = WWW::Wikipedia->new(language => 'ja');
        my $entry = $wiki->search($q) or die 'no wikipedia entry.' . encode_utf8($q);
        print 'got:', $title, "\n";

        my $sth = $dbh->prepare(q{
            update wikipedias set title = ?, content = ?, updated_at = datetime('now', 'localtime')
            where id = ?
        });
        $sth->execute($title, $entry->fulltext_basic, $wikipedia->{id});
    } else {
        my $q = defined $opts{q} ? decode_utf8($opts{q}) : '';
        my $limit = defined $opts{n} ? int($opts{n}) : 10;
        my $all_videos = get_videos($dbh, $limit, $q);

        get_wikipedia_contents($dbh, $all_videos);
    }

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table wikipedias (id integer primary key, video_id integer not null, title varchar, content varchar, created_at datetime, updated_at datetime);

