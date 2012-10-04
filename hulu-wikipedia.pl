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
getopts('n:', \%opts);

sub get_wikipedia_contents {
    my ($dbh, $all_videos) = @_;

    my $wiki = WWW::Wikipedia->new(language => 'ja');
    for my $v (@$all_videos) {
        $logger->debug($v->{title});
        my $entry = $wiki->search($v->{title});

        $logger->debug($entry->title) if $entry;

        my $sth = $dbh->prepare(q{insert into wikipedias (video_id, title, content, created_at, updated_at) values (?, ?, ?, datetime('now', 'localtime'), datetime('now', 'localtime'))});
        $sth->execute(
            $v->{id},
            $entry ? $entry->title : '',
            $entry ? $entry->fulltext_basic : '',
        ) or die 'failed to insert. url:' . $v->{url};
    }
}

try {
    use DBI;
    my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 1});

    my $limit = defined $opts{n} ? int($opts{n}) : 10;
    # all_videos
    my $sth = $dbh->prepare(q{
        select v.* from videos as v
        left join wikipedias as w on w.video_id = v.id
        where w.id is null
        order by v.updated_at desc
        limit ?
    });
    $sth->execute($limit);

    my @all_videos = ();
    while (my $row = $sth->fetchrow_hashref()){
        my $path = $row->{url};
        $path =~ s{.*\/(.*)$}{$1};
        $row->{path} = $path;
        push @all_videos, $row;
    }
    die $sth->errstr if $sth->err;

    get_wikipedia_contents($dbh, \@all_videos);

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table wikipedias (id integer primary key, video_id integer not null, title varchar, content varchar, created_at datetime, updated_at datetime);

