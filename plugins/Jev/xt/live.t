use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Time::HiRes qw(time);
use MT::Plugin::Jev::Client;
use MT::Plugin::Jev::OpenAIClient;

plan skip_all => 'Set OPENAI_API_KEY and TYPESAFE_API_KEY for four OpenAI and five Jev requests.'
    unless $ENV{TYPESAFE_API_KEY} && $ENV{OPENAI_API_KEY};

my $client = MT::Plugin::Jev::Client->new(
    api_key => $ENV{TYPESAFE_API_KEY},
    model => $ENV{JEV_MODEL} || 'jev-latest',
);
my $condition = 'システムを導入した後に困ったことが書かれている記事';
my @texts = (
    '新しいシステムを導入した。設定方法がわからず作業が止まり、とても困った。',
    '今日の天気は晴れ。公園で花の写真を撮った。',
    '新しいシステムの導入は順調だった。導入後も問題はなく、困ったことは一切ない。',
);
my @candidates = map { +{
    id => 'sample_' . $_,
    fields => [{name => 'text', label => '本文', value => $texts[$_]}],
} } 0 .. $#texts;
my $openai = MT::Plugin::Jev::OpenAIClient->new(api_key => $ENV{OPENAI_API_KEY});
my $tokens = 0;
my $embedding_start = time;
for my $text (@texts, $condition) {
    my $vector = $openai->embed($text);
    is scalar @$vector, 3072, 'live OpenAI embedding dimension';
    $tokens += $openai->usage->{prompt_tokens};
}
diag sprintf 'OpenAI prompt_tokens=%d seconds=%.3f', $tokens, time - $embedding_start;
my %results;
for my $size (1, 3) {
    my $start = time;
    my %scores;
    for (my $offset = 0; $offset < @candidates; $offset += $size) {
        my $answer = $client->evaluate_batch(
            condition => $condition,
            candidates => [@candidates[$offset .. $offset + $size - 1]],
        );
        @scores{keys %$answer} = values %$answer;
    }
    diag sprintf 'batch=%d model=%s seconds=%.3f scores=%s',
        $size, $ENV{JEV_MODEL} || 'jev-latest', time - $start,
        join(', ', map { "$_:noul=$scores{$_}{noul},score=$scores{$_}{score}" } sort keys %scores);
    ok $scores{sample_0}{noul} >= 0.5, "batch=$size: explicit difficulty matches";
    ok $scores{sample_1}{noul} < 0.5, "batch=$size: unrelated topic does not match";
    ok $scores{sample_2}{noul} < 0.5, "batch=$size: negated difficulty does not match";
    $results{$size} = [map { $scores{$_}{noul} >= 0.5 ? 1 : 0 } sort keys %scores];
}
is_deeply $results{1}, $results{3}, 'single and grouped judgments agree';
my $absence = $client->evaluate_batch(condition => 'システムの導入について書かれているが、料金には言及していない記事', candidates => [
    {id => 'absent', fields => [{name => 'text', value => 'システムの導入手順を説明する。設定画面を開き、利用者を登録する。'}]},
    {id => 'present', fields => [{name => 'text', value => 'システムの導入手順を説明する。設定画面を開き、利用者を登録する。最後に料金を確認する。月額料金は千円である。'}]},
]);
ok $absence->{absent}{noul} >= 0.5, 'absence condition matches full document';
ok $absence->{present}{noul} < 0.5, 'mention at end rejects absence condition';
diag 'Jev input_tokens=' . $client->input_tokens;
done_testing;
