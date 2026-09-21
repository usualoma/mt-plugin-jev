use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Time::HiRes qw(time);
use MT::Plugin::Jev::OpenAIEvaluator;

plan skip_all => 'Set OPENAI_API_KEY for three OpenAI Responses requests using synthetic documents.'
    unless $ENV{OPENAI_API_KEY};
my $model = $ENV{OPENAI_EVALUATION_MODEL} || 'gpt-5.4-mini';
my $client = MT::Plugin::Jev::OpenAIEvaluator->new(api_key => $ENV{OPENAI_API_KEY}, model => $model);
my @documents = (
    {id => 'difficulty', fields => [{name => 'text', value => '国産クラウドへサイトを移行した。DNSの設定方法が分からず作業が一日止まり、とても困った。'}]},
    {id => 'smooth', fields => [{name => 'text', value => '国産クラウドへのサイト移行は順調に完了した。作業中も移行後も問題はなく、困ったことは一切ない。'}]},
    {id => 'priced', fields => [{name => 'text', value => '国産クラウドへサイトを移行した。DNSの設定方法が分からず作業が一日止まり、とても困った。最後に費用も記録する。月額料金は千円である。'}]},
);
my $start = time;
my $result = $client->evaluate_batch(condition => '国産クラウドへの移行で実際に困ったことがあり、料金や費用には一切言及していない記事', candidates => \@documents);
ok $result->{difficulty}{noul} >= 0.5, 'difficulty with absent pricing matches';
ok $result->{smooth}{noul} < 0.5, 'negated difficulty does not match';
ok $result->{priced}{noul} < 0.5, 'pricing mention at end fails absence condition';
my $batch_seconds = time - $start;
$start = time;
$result = $client->evaluate_batches(condition => '国産クラウドのサイト移行について書かれている記事',
    batches => [[@documents[0..1]], [$documents[2]]]);
is scalar keys %$result, 3, 'parallel Responses requests complete';
ok !(grep { $_->{noul} < 0.5 } values %$result), 'positive topic matches all documents';
diag sprintf 'model=%s input_tokens=%d single_batch_seconds=%.3f parallel_seconds=%.3f',
    $model, $client->input_tokens, $batch_seconds, time - $start;
done_testing;
