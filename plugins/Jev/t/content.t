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

done_testing;
