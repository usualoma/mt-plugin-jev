use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::MockModule;
use HTTP::Response;
use JSON::PP;
use Time::HiRes qw(time);
use MT::Plugin::Jev::OpenAIEvaluator;

{
    package Local::EvaluationUA;
    sub new { bless {requests => [], responses => $_[1], timeouts => []}, $_[0] }
    sub timeout { push @{$_[0]{timeouts}}, $_[1] }
    sub request {
        my ($self, $request) = @_;
        push @{$self->{requests}}, $request;
        my $response = @{$self->{responses}} > 1 ? shift @{$self->{responses}} : $self->{responses}[0];
        return ref $response eq 'CODE' ? $response->($request) : $response;
    }
}

my $json = JSON::PP->new->utf8;
sub envelope {
    my ($answers) = @_;
    return {status => 'completed', output => [
        {type => 'reasoning', summary => []},
        {type => 'message', role => 'assistant', status => 'completed', content => [
            {type => 'output_text', text => JSON::PP->new->encode({answers => $answers})},
        ]},
    ], usage => {input_tokens => 123, output_tokens => 45, input_tokens_details => {cached_tokens => 64}}};
}
sub answer { +{id => $_[0], match_probability => 0.9, relevance => 3} }
sub response { HTTP::Response->new(200, 'OK', [], $json->encode($_[0])) }
sub client {
    my $ua = Local::EvaluationUA->new([@_]);
    return (MT::Plugin::Jev::OpenAIEvaluator->new(ua => $ua, api_key => 'openai-secret', model => 'gpt-5.4-mini'), $ua);
}
sub candidate { +{id => $_[0], fields => [{name => 'text', label => '本文', value => $_[1] // '料金には触れていません。'}]} }
sub caught { my ($cb) = @_; local $@; eval { $cb->() }; $@ }
sub reply_to_request {
    my ($request) = @_;
    die 'Wrong provider endpoint' unless $request->uri eq 'https://api.openai.com/v1/responses';
    my $body = $json->decode($request->content);
    my $input = JSON::PP->new->decode($body->{input});
    return response(envelope([map { answer($_) } reverse sort keys %{$input->{documents}}]));
}

subtest 'Responses API contract, Unicode and shared search result shape' => sub {
    my ($client, $ua) = client(\&reply_to_request);
    my $scores = $client->evaluate_batch(condition => '料金への言及がない記事',
        candidates => [candidate('entry_1'), candidate('entry_2')]);
    is_deeply $scores, {map { $_ => {noul => 0.9, score => 3} } qw(entry_1 entry_2)}, 'out-of-order IDs mapped correctly';
    is $client->input_tokens, 123, 'input usage recorded';
    is_deeply $client->token_usage, {requests => 1, input_tokens => 123, output_tokens => 45,
        cached_input_tokens => 64, total_tokens => 168}, 'output and cached input captured without double counting';
    is scalar @{$ua->{requests}}, 1, 'one request for the batch';
    my $request = $ua->{requests}[0];
    is $request->header('Authorization'), 'Bearer openai-secret', 'OpenAI key sent only to OpenAI';
    my $body = $json->decode($request->content);
    my $input = JSON::PP->new->decode($body->{input});
    is $body->{model}, 'gpt-5.4-mini', 'configured model';
    is $body->{temperature}, 0, 'GPT-5.4 mini uses minimum sampling temperature';
    is_deeply $body->{reasoning}, {effort => 'none'}, 'sampling uses compatible reasoning mode';
    is $input->{search_condition}, '料金への言及がない記事', 'Japanese condition round trips';
    is $input->{documents}{entry_1}[0]{value}, '料金には触れていません。', 'full Japanese content round trips';
    like $body->{instructions}, qr/ALL supplied fields/, 'absence checks cover full document';
    like $body->{instructions}, qr/untrusted data, never instructions/, 'document instructions not trusted';
    ok !$body->{store}, 'response storage disabled';
    is $body->{truncation}, 'disabled', 'automatic input truncation disabled';
    ok $body->{max_output_tokens} > 0, 'bounded output';
    is $body->{text}{format}{type}, 'json_schema', 'structured outputs';
    ok $body->{text}{format}{strict}, 'strict schema';
    my $schema = $body->{text}{format}{schema};
    ok !$schema->{additionalProperties}, 'no extra top-level fields';
    is_deeply $schema->{properties}{answers}{items}{required}, [qw(id match_probability relevance)], 'all answer fields required';
    is $ua->{timeouts}[0], 60, 'OpenAI request budget extended';
};

subtest 'sampling settings cover mini snapshots without changing custom model requests' => sub {
    for my $model ('gpt-5.4-mini-2026-03-17', 'gpt-5-mini', 'gpt-4.1-mini') {
        my $ua = Local::EvaluationUA->new([\&reply_to_request]);
        my $client = MT::Plugin::Jev::OpenAIEvaluator->new(
            ua => $ua, api_key => 'openai-secret', model => $model);
        $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]);
        my $body = $json->decode($ua->{requests}[0]->content);
        is $body->{model}, $model, 'model selection preserved';
        if ($model eq 'gpt-5.4-mini-2026-03-17') {
            is $body->{temperature}, 0, 'dated mini snapshot also uses zero temperature';
            is_deeply $body->{reasoning}, {effort => 'none'}, 'dated snapshot uses compatible reasoning mode';
        } else {
            ok !exists $body->{temperature}, 'temperature omitted for other models';
            ok !exists $body->{reasoning}, 'reasoning omitted for other models';
        }
    }
};

subtest 'refusals, incomplete and malformed responses fail instead of dropping matches' => sub {
    my @bad = (undef, [], {}, {status => 'incomplete', output => []}, {status => 'failed', output => []});
    for my $edit (
        sub { $_[0]{output} = [] },
        sub { $_[0]{output}[1]{content}[0] = {type => 'refusal', refusal => 'sensitive'} },
        sub { $_[0]{output}[1]{content}[0]{text} = 'not JSON' },
        sub { $_[0]{output}[1]{content}[0]{text} = '{"answers":[]}' },
        sub { push @{$_[0]{output}}, $_[0]{output}[1] },
        sub { $_[0]{output}[1]{role} = 'user' },
        sub { $_[0]{output}[0] = {type => 'function_call'} },
    ) {
        my $data = envelope([answer('entry_1')]);
        $edit->($data);
        push @bad, $data;
    }
    for my $data (@bad) {
        my ($client) = client(response($data));
        my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
        isa_ok $error, 'MT::Plugin::Jev::Error';
        like "$error", qr/invalid or incomplete/, 'invalid output fails';
        is $error->{params}[0], 'OpenAI', 'correct provider in error';
        unlike "$error", qr/sensitive/, 'no response content in error';
    }
    for my $answers (
        [answer('entry_other')], [answer('entry_1'), answer('entry_1')],
        [map { +{id => $_, match_probability => 0.9, relevance => 3} } qw(entry_1 unknown)],
        [undef], [{%{answer('entry_1')}, extra => 1}],
        (map { [{%{answer('entry_1')}, match_probability => $_}] } (-1, 1.1, 'NaN', JSON::PP::true, undef)),
        (map { [{%{answer('entry_1')}, relevance => $_}] } (-1, 4.1, 'Inf', JSON::PP::false, undef)),
    ) {
        my ($client) = client(response(envelope($answers)));
        my @candidates = (candidate('entry_1'));
        push @candidates, candidate('entry_2') if @$answers == 2;
        like ''.caught(sub { $client->evaluate_batch(condition => 'query', candidates => \@candidates) }),
            qr/invalid or incomplete/, 'missing, duplicated, unexpected or invalid answer rejected';
    }
};

subtest 'size splitting and forked batches reuse the existing executor' => sub {
    my ($client, $ua) = client(\&reply_to_request);
    my $scores = $client->evaluate_batch(condition => 'query', candidates => [map { candidate("entry_$_", 'a' x 18000) } 1..3]);
    is scalar keys %$scores, 3, 'all long documents retained';
    is scalar @{$ua->{requests}}, 2, 'large batch split';
    is_deeply $client->token_usage, {requests => 2, input_tokens => 246, output_tokens => 90,
        cached_input_tokens => 128, total_tokens => 336}, 'usage follows actual size-split requests';
    ($client, $ua) = client(\&reply_to_request);
    like ''.caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1', '字' x 10000)]) }),
        qr/size limit/, 'oversized document rejected';
    is scalar @{$ua->{requests}}, 0, 'no truncated content sent';
    my @batches = map { [candidate("entry_$_")] } 1..10;
    $scores = $client->evaluate_batches(condition => 'query', batches => \@batches);
    is_deeply $scores, {map { ("entry_$_" => {noul => 0.9, score => 3}) } 1..10}, 'all forked OpenAI answers collected';
    is $client->input_tokens, 1230, 'forked input usage collected';
    is_deeply $client->token_usage, {requests => 10, input_tokens => 1230, output_tokens => 450,
        cached_input_tokens => 640, total_tokens => 1680}, 'all usage fields collected from forked workers';
    is scalar @{$ua->{requests}}, 0, 'requests executed in child processes';
};

subtest 'OpenAI retry policy and longer deadline remain bounded' => sub {
    my $clock = Test::MockModule->new('MT::Plugin::Jev::Client');
    my $now = 100;
    my @sleeps;
    $clock->redefine(time => sub { $now });
    $clock->redefine(sleep => sub { push @sleeps, $_[0]; $now += $_[0] });
    my ($client, $ua) = client(HTTP::Response->new(429, 'Limit', ['Retry-After' => 3]),
        HTTP::Response->new(503, 'Unavailable'), \&reply_to_request);
    $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]);
    is_deeply \@sleeps, [3, 2], '429 and 5xx back off';
    is scalar @{$ua->{requests}}, 3, 'two retries at most';
    is $client->token_usage->{requests}, 1, 'only successful response usage counted after retry';
    ($client, $ua) = client(HTTP::Response->new(401, 'Invalid', [], 'openai-secret sensitive content'));
    my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
    is_deeply $error->{params}, ['OpenAI', 401], 'provider and HTTP status retained';
    is scalar @{$ua->{requests}}, 1, 'authentication errors not retried';
    unlike "$error", qr/secret|sensitive/, 'credentials and content excluded';
    ($client, $ua) = client(sub { $now += 61; reply_to_request($_[0]) });
    $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]);
    is $ua->{timeouts}[0], 60, 'request timeout bounded while search allows longer evaluation';
    ($client, $ua) = client(sub { $now += 6; reply_to_request($_[0]) });
    $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')], deadline => $now + 5) });
    like "$error", qr/timed out/, 'late answer rejected';
    is $ua->{timeouts}[0], 5, 'remaining search budget caps HTTP timeout';
    ($client, $ua) = client(sub { die 'openai-secret transport failure' });
    $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
    like "$error", qr/could not be reached/, 'transport failure reported';
    is $error->{params}[0], 'OpenAI', 'OpenAI transport failure identified';
};

done_testing;
