use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../t/lib";
use Test::More;
BEGIN { plan skip_all => 'Set JEV_BENCHMARK=1 for the 10,000-document benchmark.' unless $ENV{JEV_BENCHMARK} }
use MT::Plugin::Jev::Test;
use MT::Test::Permission;
use MT::Test::App;
use Test::MockModule;
use Time::HiRes qw(time);
use MT::Plugin::Jev::Search;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $openai_calls = 0;
my $openai = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
my @vector = map { sin($_ + 1) / sqrt(3072) } 0..3071;
$openai->redefine(embed => sub { $openai_calls++; [@vector] });
my $jev_calls = 0;
my $evaluated = 0;
my $jev = Test::MockModule->new('MT::Plugin::Jev::Client');
$jev->redefine(evaluate_batches => sub {
    my ($self, %args) = @_;
    $jev_calls += @{$args{batches}};
    my @candidates = map { @$_ } @{$args{batches}};
    $evaluated += @candidates;
    return {map { $_->{id} => {noul => 1, score => 3} } @candidates};
});
my $plugin = MT->component('Jev');
$plugin->set_config_value({openai_api_key => 'benchmark-fake', jev_api_key => 'benchmark-fake',
    jev_model => 'jev-latest', jev_threshold => 0.5, jev_candidate_limit => 50, jev_batch_size => 5}, 'system');
my $site = MT::Test::Permission->make_website;
my $start = time;
for my $i (1..10000) {
    MT::Test::Permission->make_entry(blog_id => $site->id, title => "Benchmark article $i",
        text => 'A cloud service deployment guide. ' x 50);
}
diag sprintf 'fixture: %.3fs; embeddings: %d', time - $start, $openai_calls;
my $app = MT::Test::App->new('MT::App::CMS');
$app->login(MT->model('author')->load(1));
$app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id});
$openai_calls = 0;
$start = time;
$app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id,
    search => 'cloud deployment', do_search => 1, is_jev => 1, limit => 'all'});
my $seconds = time - $start;
ok !$app->generic_error, '10,000 indexed articles searched' or diag $app->generic_error;
is $openai_calls, 1, 'only query is embedded';
is $evaluated, 50, 'Jev sees only 50 candidates';
is $jev_calls, 10, 'five documents per Jev request';
cmp_ok $seconds, '<', 45, 'local processing fits search deadline';
my $peak = '';
if (open my $fh, '<', '/proc/self/status') { while (<$fh>) { $peak = $_ if /^VmHWM:/ } }
diag sprintf 'search: %.3fs (real MT, DB reads, hashes, vector comparison and rendering; APIs mocked); %s', $seconds, $peak;
done_testing;
