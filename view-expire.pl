#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Encode;
use Data::Dumper;

use URI;
use Web::Scraper;

my $scraper = scraper {
    process 'section.tl-tweets p.tl-text', 'text[]' => 'TEXT';
};

my $uri = new URI('http://twilog.org/Hulu_JPSupport/hashtags-hulu_%E9%85%8D%E4%BF%A1%E6%9C%9F%E9%99%90');

# 先ほどのスクレイパーに渡す。（スクレイピングされる）
my $res = $scraper->scrape($uri);

foreach my $text (@{$res->{text}}) {
    print encode_utf8($text), "\n";
}

