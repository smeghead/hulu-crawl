#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use LWP;
use Encode;
use Net::Twitter;
use Data::Dumper;

my $api_url = 'http://www2.hulu.jp/content?country=all&genre=%E3%83%89%E3%83%A9%E3%83%9E&type_group=all&ajax=true&page=';

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
            print 'exists ' . encode_utf8($v->{title}) if $v->{url} eq $adds->[0]->{url};
            next V if $v->{url} eq $adds->[0]->{url};
        }
        push @new_videos, $nv;
    }
    return @new_videos;
}

sub twitter_post {
    my ($message) = @_;

    my $nt = Net::Twitter->new(
        traits   => [qw/OAuth API::REST/],
        consumer_key => 'UjrLWT5AwoDej7uln9nFQ',
        consumer_secret => 'IVT4epWYZSA0qzJRu1tJXabEDfbV3ZjLtfdm4GwTE4',
        access_token => '842246437-WquJX5oxiMNQX9bwqwdYbxV8ckoGhYHikfP8Mqht',
        access_token_secret => 'eDi9SyJiuonY691OYpCDe19CiaSCDiDtNrnOV8YHUM',
    );

    $nt->update($message) or die $@;
}

my @videos = ();
for my $p (1 .. 100) {
    my $content = LWP::UserAgent->new->request(HTTP::Request->new(GET => $api_url . $p))->content;
    $content = decode_utf8($content);
    print 'content utf8', Encode::is_utf8($content), "\n";
    my @adds = parse_videos($content);
    @adds = exists_check(\@videos, \@adds);
    last unless scalar @adds;

    push @videos, @adds;
}

use DBI;
use FindBin;
my $dbh = DBI->connect('dbi:SQLite:dbname=' . $FindBin::Bin . '/videos.db', "", "", {PrintError => 1, AutoCommit => 0});

for my $v (@videos) {
    my $select = "select * from videos where url = ?";
    my $sth = $dbh->prepare($select);
    $sth->execute($v->{url});
    if (my $old = $sth->fetchrow_hashref) {
        if ($old->{seasons} != $v->{seasons} or $old->{episodes} != $v->{episodes}) {
            print 'changed.', "\n";
            print 'is_utf8: ' . Encode::is_utf8($v->{title}), "\n";
            my $message = 
                '[' . $v->{title} . '] が更新されました。' .
                $old->{seasons} . '(' . $old->{episodes} . ') -> ' . $v->{seasons} . '(' . $v->{episodes} . ')';
            twitter_post($message);
            print encode_utf8($message), "\n";

            $sth = $dbh->prepare('update videos set seasons = ?, episodes = ?, updated_at = current_timestamp where id = ?');
            $sth->execute(
                $v->{seasons},
                $v->{episodes},
                $old->{id},
            ) or die 'failed to update. url:' . $v->{title};
        }
    } else {
        print 'is_utf8: ' . Encode::is_utf8($v->{title}), "\n";
        my $message = '[' . $v->{title} . '] が追加されました。';
        twitter_post($message);
        print encode_utf8($message), "\n";
        $sth = $dbh->prepare('insert into videos (url, title, seasons, episodes, created_at, updated_at) values (?, ?, ?, ?, current_timestamp, current_timestamp)');
        $sth->execute(
            $v->{url},
            $v->{title},
            $v->{seasons},
            $v->{episodes},
        ) or die 'failed to insert. url:' . $v->{title};
    }
}

$dbh->commit;
$dbh->disconnect;
__END__

create table videos (id integer primary key, url varchar, title varchar, seasons integer, episodes integer, created_at datetime, updated_at datetime);

