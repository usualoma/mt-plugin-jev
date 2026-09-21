use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::MockModule;
use HTTP::Response;
use JSON::PP;
use MT::Plugin::Jev::Client;

{
    package Local::UA;
    sub new { bless { requests => [], responses => $_[1], timeouts => [] }, $_[0] }
    sub timeout { push @{ $_[0]{timeouts} }, $_[1] }
    sub request {
        my ($self, $request) = @_;
        push @{ $self->{requests} }, $request;
        my $response = shift @{ $self->{responses} };
        return ref($response) eq 'CODE' ? $response->($request) : $response;
    }
}

my $json = JSON::PP->new->utf8;
my $clock = Test::MockModule->new('MT::Plugin::Jev::Client');
my ($now, @sleeps);
$clock->redefine(time => sub { $now });
$clock->redefine(sleep => sub { push @sleeps, $_[0]; $now += $_[0] });

sub response {
    my ($scores) = @_;
    return HTTP::Response->new(200, 'OK', [], $json->encode({
        answers => { map { ($_ . '_match' => { type => 'noul', noul => $scores->{$_} }, $_ . '_score' => {type => 'score', score => 3}) } keys %$scores },
        usage => {input_tokens => 123},
    }));
}

sub client {
    my (@responses) = @_;
    $now = 100;
    @sleeps = ();
    my $ua = Local::UA->new(\@responses);
    return (MT::Plugin::Jev::Client->new(ua => $ua, api_key => 'secret-test-key', model => 'jev-latest'), $ua);
}

sub candidate { +{ id => $_[0], fields => [{ name => 'text', label => '本文', value => $_[1] // '設定に苦労した。' }] } }
sub caught { my ($code) = @_; local $@; eval { $code->() }; return $@ }

subtest 'native contract, Unicode and identity' => sub {
    my ($client, $ua) = client(response({entry_2 => 0.5, entry_1 => 0.1}));
    my $scores = $client->evaluate_batch(condition => '導入後に困った記事', candidates => [candidate('entry_1'), candidate('entry_2')]);
    is_deeply $scores, {entry_1 => {noul => 0.1, score => 3}, entry_2 => {noul => 0.5, score => 3}}, 'answers mapped by ID, not order';
    is scalar @{ $ua->{requests} }, 1, 'one request for two candidates';
    my $req = $ua->{requests}[0];
    is $req->uri, MT::Plugin::Jev::Client::ENDPOINT, 'official endpoint';
    is $req->header('Authorization'), 'Bearer secret-test-key', 'Bearer authentication';
    my $body = $json->decode($req->content);
    is $body->{state}{search_condition}, '導入後に困った記事', 'Unicode condition round trips';
    is $body->{state}{documents}{entry_1}[0]{value}, '設定に苦労した。', 'document is shared by its two questions';
    is $body->{questions}{entry_1_match}{type}, 'noul', 'Noul question';
    is $body->{questions}{entry_1_score}{type}, 'score', 'Score question';
    is scalar @{$body->{questions}{entry_1_score}{criteria}}, 5, 'five descriptive levels';
    like $body->{questions}{entry_1_match}{instructions}, qr/state.documents.entry_1/, 'target is explicit in instructions';
    is $client->input_tokens, 123, 'usage available without logging content';
    is $body->{model}, 'jev-latest', 'model sent';
};

subtest 'size splitting and oversized single candidate' => sub {
    my $reply = sub {
        my $body = $json->decode($_[0]->content);
        return response({map { $_ => 0.7 } keys %{ $body->{state}{documents} }});
    };
    my ($client, $ua) = client($reply, $reply);
    my $scores = $client->evaluate_batch(condition => '長い本文', candidates => [map { candidate("entry_$_", 'a' x 18000) } 1..3]);
    is scalar @{ $ua->{requests} }, 2, 'size splits a batch into multiple requests';
    is scalar keys %$scores, 3, 'all candidates retained';
    ok !(grep { length($_->content) > MT::Plugin::Jev::Client::MAX_REQUEST_BYTES } @{ $ua->{requests} }), 'all requests fit budget';
    ($client, $ua) = client();
    my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_99', '字' x 10000)]) });
    isa_ok $error, 'MT::Plugin::Jev::Error';
    like "$error", qr/size limit/, 'oversize reported';
    is scalar @{ $ua->{requests} }, 0, 'no truncated content sent';
};

subtest 'invalid answers never become nonmatches' => sub {
    for my $body (
        'not JSON', '[]', '{}',
        $json->encode({answers => {}}),
        $json->encode({answers => {entry_1 => {type => 'choice', noul => 0.9}}}),
        $json->encode({answers => {entry_1 => {type => 'noul', noul => 1.01}}}),
        $json->encode({answers => {entry_1 => {type => 'noul', noul => -0.1}}}),
        $json->encode({answers => {entry_1 => {type => 'noul', noul => 'NaN'}}}),
        $json->encode({answers => {entry_1 => {type => 'noul', noul => JSON::PP::true}}}),
        $json->encode({answers => {entry_other => {type => 'noul', noul => 0.9}}}),
    ) {
        my ($client) = client(HTTP::Response->new(200, 'OK', [], $body));
        my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
        isa_ok $error, 'MT::Plugin::Jev::Error';
        like "$error", qr/invalid or incomplete/, 'invalid response is a failure';
    }
};

subtest 'a malformed Score or missing paired answer fails the whole evaluation' => sub {
    for my $value (-1, 4.01, 'NaN', 'Infinity', JSON::PP::true, undef) {
        my $data = $json->decode(response({entry_1 => 0.9})->content);
        $data->{answers}{entry_1_score}{score} = $value;
        my ($client) = client(HTTP::Response->new(200, 'OK', [], $json->encode($data)));
        like ''.caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) }),
            qr/invalid or incomplete/, 'invalid Score is not silently skipped';
    }
};

subtest 'bounded retries, Retry-After and sanitized errors' => sub {
    my ($client, $ua) = client(HTTP::Response->new(429, 'Limit', ['Retry-After' => 3]), HTTP::Response->new(529, 'Overloaded'), response({entry_1 => 1}));
    my $result = $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]);
    is $result->{entry_1}{noul}, 1, 'retry succeeds';
    is_deeply \@sleeps, [3, 2], 'backoff respects Retry-After';
    is scalar @{ $ua->{requests} }, 3, 'bounded attempts';
    for my $status (401, 422, 500, 429, 529) {
        ($client, $ua) = client(map { HTTP::Response->new($status, 'Error', [], 'secret-test-key sensitive body') } 1..3);
        my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
        like "$error", qr/HTTP/, "HTTP $status fails";
        unlike "$error", qr/secret|sensitive/, 'response body not exposed';
        is scalar @{ $ua->{requests} }, ($status == 429 || $status == 529 ? 3 : 1), 'only transient statuses retried';
    }
    ($client, $ua) = client(HTTP::Response->new(429, 'Limit', ['Retry-After' => 100]));
    caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')], deadline => 101) });
    is_deeply \@sleeps, [], 'does not wait past deadline or retry early';
};

subtest 'deadline and transport failure' => sub {
    my ($client, $ua) = client();
    my $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')], deadline => 99) });
    like "$error", qr/timed out/, 'deadline checked before sending';
    is scalar @{ $ua->{requests} }, 0, 'no late request';
    ($client, $ua) = client(sub { $now = 200; response({entry_1 => 1}) });
    $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')], deadline => 105) });
    like "$error", qr/timed out/, 'late answer is not returned as complete';
    is $ua->{timeouts}[0], 5, 'request timeout capped to remaining budget';
    ($client, $ua) = client(sub { die 'transport secret-test-key' });
    $error = caught(sub { $client->evaluate_batch(condition => 'query', candidates => [candidate('entry_1')]) });
    like "$error", qr/could not be reached/, 'transport error reported';
    unlike "$error", qr/secret-test-key/, 'transport details not exposed';
};

done_testing;
