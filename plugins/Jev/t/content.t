use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use MT::Plugin::Jev::Content;

is MT::Plugin::Jev::Content::plain_text('<p>設定 &amp; 運用</p><p>失敗した。</p><script>secret()</script><style>.secret{}</style>'),
    '設定 & 運用 失敗した。', 'HTML becomes readable text without executable content';
is MT::Plugin::Jev::Content::plain_text('<!-- mt-beb t="text" --><p>ブロックの本文</p><!-- /mt-beb -->'),
    'ブロックの本文', 'block editor comments omitted, rendered content retained';
is MT::Plugin::Jev::Content::plain_text('<table><tr><td>A</td><td>B</td></tr></table><img alt="図の説明">'),
    'A B 図の説明', 'tables and image alternatives preserved';
is MT::Plugin::Jev::Content::plain_text('0'), '0', 'zero is retained';
is MT::Plugin::Jev::Content::plain_text('2 < 3'), '2 < 3', 'plain comparison is retained';
is_deeply MT::Plugin::Jev::Content::plain_text(['<b>A</b>', {text => '<p>B</p>'}]),
    ['A', {text => 'B'}], 'structured values are not Perl reference strings';

subtest 'shorten only the embedding copy, preserving titles and valid Unicode JSON' => sub {
    my $json = JSON::PP->new->canonical;
    my $fields = [
        {name => 'text_more', label => 'text_more', value => '続きの本文😀' x 1000},
        {name => 'title', label => 'title', value => '残すタイトル'},
        {name => 'text', label => 'text', value => '短い導入'},
    ];
    my $text = $json->encode($fields);
    my $short = MT::Plugin::Jev::Content->shorten_index_text($text, 0.9);
    my $decoded = $json->decode($short);
    is $decoded->[1]{value}, '残すタイトル', 'title retained';
    is $decoded->[2]{value}, '短い導入', 'short introduction retained';
    cmp_ok length($decoded->[0]{value}), '<', length($fields->[0]{value}), 'long continuation trimmed';
    is index($fields->[0]{value}, $decoded->[0]{value}), 0, 'beginning retained';
    unlike $short, qr/\x{fffd}/, 'no broken Unicode';
    is $json->encode($fields), $text, 'source fields untouched';
    my $structured = $json->encode([
        {name => '__field:1', value => [{label => '日本語' x 1000, id => 123}, undef, JSON::PP::true]},
        {name => 'label', value => 'コンテンツのタイトル'},
    ]);
    my $short_structured = $json->decode(MT::Plugin::Jev::Content->shorten_index_text($structured, 0.8));
    is $short_structured->[1]{value}, 'コンテンツのタイトル', 'content data label retained';
    is $short_structured->[0]{value}[0]{id}, 123, 'short nested ID retained';
    ok $short_structured->[0]{value}[2], 'JSON boolean retained';
    cmp_ok length($short_structured->[0]{value}[0]{label}), '<', 3000, 'nested text trimmed';
    my $title_only = $json->encode([{name => 'title', value => '長いタイトル' x 1000}]);
    cmp_ok length(MT::Plugin::Jev::Content->shorten_index_text($title_only, 0.5)), '<', length($title_only),
        'oversized title can be shortened as a last resort';
};

done_testing;
