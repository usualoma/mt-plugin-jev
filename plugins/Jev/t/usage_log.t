use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use Test::MockModule;
use MT::Test::Permission;
use MT::Test::App;
use HTTP::Response;
use JSON::PP;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $json = JSON::PP->new->utf8;
my ($fail, $matches, $omit_usage) = (0, 1, 0);
my $http = Test::MockModule->new('LWP::UserAgent');
$http->redefine(request => sub {
    my ($ua, $request) = @_;
    my $body = $json->decode($request->content);
    my $data;
    if ($request->uri eq 'https://api.openai.com/v1/embeddings') {
        $data = {model => 'text-embedding-3-large', data => [{object => 'embedding', index => 0,
            embedding => [1, (0) x 3071]}], usage => {prompt_tokens => 17, total_tokens => 17}};
    } else {
        return HTTP::Response->new(401, 'Error', [], 'private-content secret-key') if $fail;
        if ($request->uri eq 'https://api.typesafe.ai/v1/systemone') {
            $data = {answers => {map { ($_ . '_match' => {type => 'noul', noul => $matches ? 0.9 : 0.1},
                $_ . '_score' => {type => 'score', score => 3}) } keys %{$body->{state}{documents}}},
                usage => {input_tokens => 100, output_tokens => 20}};
        } else {
            die 'Unexpected endpoint' unless $request->uri eq 'https://api.openai.com/v1/responses';
            my $input = JSON::PP->new->decode($body->{input});
            $data = {status => 'completed', output => [{type => 'message', role => 'assistant',
                content => [{type => 'output_text', text => JSON::PP->new->encode({answers => [map {
                    +{id => $_, match_probability => $matches ? 0.9 : 0.1, relevance => 3}
                } keys %{$input->{documents}}]})}]}],
                usage => {input_tokens => 100, output_tokens => 12, input_tokens_details => {cached_tokens => 64}}};
        }
    }
    delete $data->{usage} if $omit_usage;
    return HTTP::Response->new(200, 'OK', [], $json->encode($data));
});
my $plugin = MT->component('Jev');
$plugin->set_config_value({openai_api_key => 'secret-openai-key', jev_api_key => 'secret-jev-key',
    jev_batch_size => 1, jev_concurrency => 5}, 'system');
my $site = MT::Test::Permission->make_website(name => 'Usage logging');
my @entries = map { MT::Test::Permission->make_entry(blog_id => $site->id,
    title => "Private title $_", text => 'Private article body') } 1..3;
my $admin = MT->model('author')->load(1);
my $app = MT::Test::App->new('MT::App::CMS');
$app->login($admin);
sub search {
    $app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id,
        search => 'private search condition', do_search => 1, is_jev => 1, @_});
}
sub logs { [MT->model('log')->load({category => 'jev_usage'}, {sort => 'id', direction => 'ascend'})] }
sub record {
    my ($log) = @_;
    my $message = $log->message;
    $message =~ s/\AJev search token usage: // or die 'Missing usage prefix';
    return JSON::PP->new->decode($message);
}

search();
ok !$app->generic_error, 'default search succeeds';
is scalar @{logs()}, 0, 'OFF by default creates no usage log';
$plugin->set_config_value('jev_log_usage', 1, 'system');
for my $provider (qw(jev openai)) {
    $plugin->set_config_value('jev_evaluator', $provider, 'system');
    for my $concurrency (1, 5) {
        $plugin->set_config_value('jev_concurrency', $concurrency, 'system');
        my $before = scalar @{logs()};
        search();
        ok !$app->generic_error, "$provider search completes with $concurrency workers" or diag $app->generic_error;
        my $logs = logs();
        is scalar @$logs, $before + 1, 'one log for the whole search, not per worker';
        my $log = $logs->[-1];
        my $record = record($log);
        is $log->blog_id, $site->id, 'log is attached to search site';
        is $log->author_id, $admin->id, 'log identifies searching user';
        is $record->{object_type}, 'entry', 'search type recorded';
        is $record->{embedding}{input_tokens}, 17, 'only query embedding counted';
        is $record->{embedding}{requests}, 1, 'one embedding request';
        is $record->{evaluation}{requests}, 3, 'all evaluation batches counted';
        is $record->{evaluation}{input_tokens}, 300, 'all evaluation input tokens added';
        is $record->{evaluation}{provider}, $provider eq 'jev' ? 'Jev' : 'OpenAI', 'provider identified';
        is $record->{total}{input_tokens}, 317, 'embedding and evaluation input combined';
        if ($provider eq 'openai') {
            is $record->{evaluation}{model}, 'gpt-5.4-mini', 'evaluation model recorded';
            is $record->{evaluation}{output_tokens}, 36, 'output summed across batches';
            is $record->{evaluation}{cached_input_tokens}, 192, 'cached input summed across batches';
            is $record->{total}{total_tokens}, 353, 'cached input not counted twice';
        } else {
            is $record->{evaluation}{output_tokens}, 60, 'Jev output summed across batches';
            is $record->{total}{total_tokens}, 377, 'Jev input and output included in total';
            ok !defined $record->{evaluation}{cached_input_tokens}, 'unreported cache count recorded as null';
        }
        unlike $log->message, qr/private|secret|article body/i, 'no query, content, or credentials logged';
    }
}
my $before = scalar @{logs()};
search(is_jev => 0);
is scalar @{logs()}, $before, 'ordinary search does not log token usage';
$app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id, is_jev => 1});
is scalar @{logs()}, $before, 'opening an unsearched form does not log';
$fail = 1;
search();
ok $app->generic_error, 'failed evaluation still reports an error';
is scalar @{logs()}, $before, 'failed search does not log incomplete usage as complete';
$fail = 0;
$matches = 0;
search();
is scalar @{logs()}, ++$before, 'completed search with no matches logs usage';
$omit_usage = 1;
search();
my $unknown = record(logs()->[-1]);
ok !defined $unknown->{total}{input_tokens}, 'missing API usage is null rather than zero';
$omit_usage = 0;
my $empty_site = MT::Test::Permission->make_website(name => 'Empty site');
search(blog_id => $empty_site->id);
my $empty = record(logs()->[-1]);
is $empty->{total}{requests}, 0, 'empty search makes no API requests';
is $empty->{total}{total_tokens}, 0, 'empty search logs zero usage';
$plugin->set_config_value('jev_log_usage', 0, 'system');
$before = scalar @{logs()};
search();
is scalar @{logs()}, $before, 'logging stops when disabled';

done_testing;
