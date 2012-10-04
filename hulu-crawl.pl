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

use Log::Log4perl;

my $logfile = $FindBin::Bin . '/hulu-crawl.log';
my $conf = qq(
    log4perl.logger.main          = DEBUG, Logfile, Screen

    log4perl.appender.Logfile          = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename = $logfile
    log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::SimpleLayout
    log4perl.appender.Logfile.layout.ConversionPattern = [%r] %F %L %m%n

    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
);
Log::Log4perl->init(\$conf);
my $logger = Log::Log4perl->get_logger('main');

# my $api_url = 'http://www2.hulu.jp/content?country=all&genre=%E3%83%89%E3%83%A9%E3%83%9E&type_group=all&ajax=true&page=';
my $api_url = 'http://www2.hulu.jp/content?country=all&genre=all&type_group=all&ajax=true&page=';

my %opts = ();
getopts('p:', \%opts);

sub parse_videos {
    my ($content) = @_;

    $content =~ s{\A.*\$\("\#show-results-list"\)\.replaceWith\("(.*)"\);.*\z}{$1}xms;
    $content =~ s{\\}{}g;
    return grep {$_} map {
        my ($url, $title) = $_ =~ m{
            show-title-container .*
            href="([^"]+)" .*
            class="bold-link">([^<]+)</a> .*
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

    $logger->info(encode_utf8($message));
    my $nt = Net::Twitter->new(
        traits   => [qw/OAuth API::REST/],
        consumer_key => 'UjrLWT5AwoDej7uln9nFQ',
        consumer_secret => 'IVT4epWYZSA0qzJRu1tJXabEDfbV3ZjLtfdm4GwTE4',
        access_token => '842246437-WquJX5oxiMNQX9bwqwdYbxV8ckoGhYHikfP8Mqht',
        access_token_secret => 'eDi9SyJiuonY691OYpCDe19CiaSCDiDtNrnOV8YHUM',
    );

    if (defined $opts{p} && $opts{p} eq 'true') {
        $nt->update($message) or die $@;
    } else {
        $logger->debug('not post.');
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

    for my $v (@videos) {
        $logger->debug($v->{url});
        my $select = "select * from videos where url = ?";
        my $sth = $dbh->prepare($select);
        $sth->execute($v->{url});
        if (my $old = $sth->fetchrow_hashref) {
            if ($old->{seasons} != $v->{seasons} or $old->{episodes} != $v->{episodes}) {
                $logger->info('changed.');
                my $message = 
                    '[' . $v->{title} . '] が更新されました。' .
                    $old->{seasons} . '(' . $old->{episodes} . ') -> ' . $v->{seasons} . '(' . $v->{episodes} . ') ' . $v->{url};
                twitter_post($message);
                $sth = $dbh->prepare('insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 0, ?, ?, current_timestamp, current_timestamp)');
                $sth->execute(
                    $old->{id},
                    $v->{seasons},
                    $v->{episodes},
                ) or die 'failed to insert. url:' . $v->{title};
            }
            $sth = $dbh->prepare('update videos set seasons = ?, episodes = ?, updated_at = current_timestamp where id = ?');
            $sth->execute(
                $v->{seasons},
                $v->{episodes},
                $old->{id},
            ) or die 'failed to update. url:' . $v->{title};
        } else {
            my $message = '[' . $v->{title} . '] が追加されました。' . $v->{url};
            twitter_post($message);
            $sth = $dbh->prepare('insert into videos (url, title, seasons, episodes, created_at, updated_at) values (?, ?, ?, ?, current_timestamp, current_timestamp)');
            $sth->execute(
                $v->{url},
                $v->{title},
                $v->{seasons},
                $v->{episodes},
            ) or die 'failed to insert. url:' . $v->{title};
            my $last_insert_id = $dbh->func('last_insert_rowid');
            print 'new id:' . $last_insert_id, "\n";
            $sth = $dbh->prepare('insert into updates (video_id, is_new, seasons, episodes, created_at, updated_at) values (?, 1, ?, ?, current_timestamp, current_timestamp)');
            $sth->execute(
                $last_insert_id,
                $v->{seasons},
                $v->{episodes},
            ) or die 'failed to insert. url:' . $v->{title};
        }
    }

    $dbh->disconnect;
} catch {
    $logger->error_die("caught error: $_");
};
$logger->info('finished cleanly.');

__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);
create table updates (id integer primary key, video_id integer not null, is_new integer not null, seasons integer, episodes integer, created_at datetime, updated_at datetime);

