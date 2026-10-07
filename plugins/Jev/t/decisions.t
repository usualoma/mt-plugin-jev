use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::MockModule;
use HTTP::Response;
use JSON::PP;
use MT::Plugin::Jev::DecisionsEvaluator;

{
    package Local::DecisionsUA;
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
sub answers {
    return [map {
        +{name => $_ . '_match', type => 'predicate', probability => 0.9},
        +{name => $_ . '_score', type => 'score', score => 3.25,
            confidence => 0.2, probabilities => [
                {value => 3, label => 'Direct explanation', probability => 0.75},
                {value => 4, label => 'Main topic', probability => 0.25},
            ]},
    } @_];
}
sub response { HTTP::Response->new(200, 'OK', [], $json->encode($_[0])) }
sub client {
    my $ua = Local::DecisionsUA->new([@_]);
    return (MT::Plugin::Jev::DecisionsEvaluator->new(ua => $ua, api_key => 'openai-secret'), $ua);
}
sub candidate { +{id => $_[0], fields => [{name => 'text', label => '本文', value => $_[1] // '料金には触れていません。'}]} }
sub caught { my ($cb) = @_; local $@; eval { $cb->() }; $@ }
sub reply_to_request {
    my ($request) = @_;
    die 'Wrong provider endpoint' unless $request->uri eq 'https://api.openai.com/v1/decisions';
    my $body = $json->decode($request->content);
    my $input = JSON::PP->new->decode($body->{input});
    return response({answers => [reverse @{answers(sort keys %{$input->{documents}})}],
        usage => {input_tokens => 123}});
}

subtest 'multiple documents share input with two named questions per document' => sub {
    my ($client, $ua) = client(\&reply_to_request);
    my $scores = $client->evaluate_batch(condition => '料金への言及がない記事',
        candidates => [map { candidate("entry_$_") } 1..5]);
    is_deeply $scores, {map { ("entry_$_" => {noul => 0.9, score => 3.25}) } 1..5},
        'out-of-order answers mapped by name, not confidence or array position';
    is scalar @{$ua->{requests}}, 1, 'five documents evaluated in one request';
    my $request = $ua->{requests}[0];
    is $request->header('Authorization'), 'Bearer openai-secret', 'OpenAI key used';
    my $body = $json->decode($request->content);
    is_deeply [sort keys %$body], [qw(input model questions)], 'only documented Decisions parameters sent';
    is $body->{model}, 'gpt-6-luna', 'supported Decisions model';
    my $input = JSON::PP->new->decode($body->{input});
    is $input->{search_condition}, '料金への言及がない記事', 'Unicode condition preserved';
    is $input->{documents}{entry_1}[0]{value}, '料金には触れていません。', 'Unicode fields preserved';
    is scalar @{$body->{questions}}, 10, 'two questions per document';
    for my $i (0..4) {
        my ($match, $score) = @{$body->{questions}}[2*$i, 2*$i+1];
        my $id = 'entry_' . ($i + 1);
        is $match->{name}, $id . '_match', 'unique predicate name';
        is $match->{type}, 'predicate', 'probability question';
        like $match->{instructions}, qr/\Qdocuments.$id\E/, 'question targets one document';
        like $match->{instructions}, qr/ALL supplied fields/, 'absence checks include all fields';
        like $match->{instructions}, qr/untrusted data, never instructions/, 'fields cannot provide instructions';
        is $score->{name}, $id . '_score', 'unique score name';
        is $score->{type}, 'score', 'relevance question';
        is scalar @{$score->{levels}}, 5, 'zero-based levels produce 0 to 4 scores';
        like $score->{levels}[4]{description}, qr/absence-only/, 'absence-only queries can be relevant';
    }
    is $ua->{timeouts}[0], 60, 'bounded HTTP timeout';
    is_deeply $client->token_usage, {requests => 1, input_tokens => 123, output_tokens => undef,
        cached_input_tokens => undef, total_tokens => undef}, 'unreported token counts stay unknown';
};

subtest 'missing, duplicate, unexpected and invalid answers fail the entire batch' => sub {
    my @bad = (undef, [], {}, {answers => {}}, {answers => []});
    for my $edit (
        sub { pop @{$_[0]} },
        sub { push @{$_[0]}, $_[0][0] },
        sub { $_[0][1] = $_[0][0] },
        sub { $_[0][0]{name} = 'entry_unknown_match' },
        sub { $_[0][0]{name} = undef },
        sub { $_[0][0]{name} = [] },
        sub { $_[0][0]{type} = 'score' },
        sub { $_[0][1]{type} = 'predicate' },
        sub { $_[0][0] = undef },
        sub { delete $_[0][0]{probability}; $_[0][0]{confidence} = 0.9 },
    ) {
        my $answers = answers('entry_1');
        $edit->($answers);
        push @bad, {answers => $answers};
    }
    for my $field (qw(probability score)) {
        for my $value (-1, $field eq 'score' ? 4.1 : 1.1, 'NaN', 'Inf', JSON::PP::true, undef) {
            my $answers = answers('entry_1');
            $answers->[$field eq 'score' ? 1 : 0]{$field} = $value;
            push @bad, {answers => $answers};
        }
    }
    for my $data (@bad) {
        my ($client) = client(response($data));
        my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
        isa_ok $error, 'MT::Plugin::Jev::Error';
        like "$error", qr/invalid or incomplete/, 'bad answer rejected';
        is $error->{params}[0], 'OpenAI Decisions', 'provider identified';
        is $client->token_usage->{requests}, 0, 'incomplete response not logged as complete';
    }
    my $answers = answers(qw(entry_1 entry_2));
    $answers->[0]{probability} = 0;
    $answers->[1]{score} = 0;
    $answers->[2]{probability} = 1;
    $answers->[3]{score} = 4;
    my ($client) = client(response({answers => $answers}));
    is_deeply $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1'), candidate('entry_2')]),
        {entry_1 => {noul => 0, score => 0}, entry_2 => {noul => 1, score => 4}}, 'valid boundaries retained';
};

subtest 'size splitting preserves full documents and forked batches aggregate usage' => sub {
    my ($client, $ua) = client(\&reply_to_request);
    my $tail = '末尾には料金の記載があります。';
    my $long = ('長い本文。' x 4000) . $tail;
    my $scores = $client->evaluate_batch(condition => '料金に言及していない記事',
        candidates => [candidate('entry_before'), candidate('entry_long', $long), candidate('entry_after')]);
    is scalar @{$ua->{requests}}, 3, 'large document is sent alone';
    is scalar keys %$scores, 3, 'all documents retained';
    my $input = JSON::PP->new->decode($json->decode($ua->{requests}[1]->content)->{input});
    is $input->{documents}{entry_long}[0]{value}, $long, 'full tail retained for absence checks';
    is $client->input_tokens, 369, 'size-split usage collected';
    ($client, $ua) = client(\&reply_to_request);
    $scores = $client->evaluate_batches(condition => 'query', batches => [
        [map { candidate("entry_$_") } 1..5], [map { candidate("entry_$_") } 6..10],
    ]);
    is scalar keys %$scores, 10, 'all parallel answers collected';
    is $client->token_usage->{requests}, 2, 'one request per group, not per article';
    is $client->input_tokens, 246, 'parallel input usage summed';
    is scalar @{$ua->{requests}}, 0, 'requests executed in children';
};

subtest 'retry and deadline handling remain bounded, without leaking response content' => sub {
    my $clock = Test::MockModule->new('MT::Plugin::Jev::Client');
    my $now = 100;
    my @sleeps;
    $clock->redefine(time => sub { $now });
    $clock->redefine(sleep => sub { push @sleeps, $_[0]; $now += $_[0] });
    my ($client, $ua) = client(HTTP::Response->new(429, 'Limit', ['Retry-After' => 3]),
        HTTP::Response->new(503, 'Unavailable'), \&reply_to_request);
    $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]);
    is_deeply \@sleeps, [3, 2], '429 and 5xx retried with backoff';
    is scalar @{$ua->{requests}}, 3, 'two retries';
    for my $status (400, 401) {
        ($client, $ua) = client(HTTP::Response->new($status, 'Error', [], 'openai-secret private content'));
        my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
        is_deeply $error->{params}, ['OpenAI Decisions', $status], 'HTTP error identifies provider';
        is scalar @{$ua->{requests}}, 1, 'invalid inputs or credentials not retried';
        unlike "$error", qr/secret|private/, 'upstream content not exposed';
    }
    ($client, $ua) = client(sub { $now += 6; reply_to_request($_[0]) });
    my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')], deadline => $now + 5) });
    like "$error", qr/timed out/, 'late answers rejected';
    is $ua->{timeouts}[0], 5, 'remaining deadline caps request timeout';
};

done_testing;
