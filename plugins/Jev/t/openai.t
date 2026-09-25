use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::MockModule;
use JSON::PP;
use HTTP::Response;
use MT::Plugin::Jev::OpenAIClient;
use MT::Plugin::Jev::Content;

{
    package Local::OpenAIUA;
    sub new { bless {response => $_[1], requests => []}, $_[0] }
    sub timeout { $_[0]{timeout} = $_[1] }
    sub request {
        my ($self, $req) = @_;
        push @{$self->{requests}}, $req;
        return ref($self->{response}) eq 'CODE' ? $self->{response}->() : $self->{response};
    }
}
my $json = JSON::PP->new->utf8;
sub body { +{model => 'text-embedding-3-large', data => [{object => 'embedding', index => 0,
    embedding => [1, (0) x 3071]}], usage => {prompt_tokens => 15}} }
sub client {
    my ($body, $status) = @_;
    my $ua = Local::OpenAIUA->new(HTTP::Response->new($status || 200, 'Response', [],
        ref($body) ? $json->encode($body) : $body));
    return (MT::Plugin::Jev::OpenAIClient->new(api_key => 'unit-secret', ua => $ua), $ua);
}
sub caught { my ($code) = @_; local $@; eval { $code->() }; $@ }
my ($client, $ua) = client(body());
is_deeply $client->embed('導入後の困難'), [1, (0) x 3071], 'full vector returned';
is $client->usage->{prompt_tokens}, 15, 'usage available';
is_deeply $client->token_usage, {requests => 1, input_tokens => 15, output_tokens => 0,
    cached_input_tokens => 0, total_tokens => 15}, 'embedding prompt tokens normalized';
my $request = $ua->{requests}[0];
is $request->uri, 'https://api.openai.com/v1/embeddings', 'fixed official URL';
is $request->header('Authorization'), 'Bearer unit-secret', 'authentication';
is_deeply $json->decode($request->content), {model => 'text-embedding-3-large',
    dimensions => 3072, encoding_format => 'float', input => '導入後の困難'}, 'synchronous embedding contract';

for my $mutate (
    sub { $_[0]{data}[0]{index} = 1 },
    sub { $_[0]{model} = 'wrong-model' },
    sub { pop @{$_[0]{data}[0]{embedding}} },
    sub { push @{$_[0]{data}}, $_[0]{data}[0] },
    sub { $_[0]{data}[0]{embedding}[0] = 'NaN' },
    sub { $_[0]{data}[0]{embedding}[0] = 'Infinity' },
    sub { $_[0]{data}[0]{embedding}[0] = 0 },
    sub { $_[0]{data}[0]{embedding}[0] = JSON::PP::true },
) {
    my $data = body(); $mutate->($data);
    ($client, $ua) = client($data);
    like ''.caught(sub { $client->embed('query') }), qr/invalid embedding/, 'malformed vector rejected';
}
for my $status (400, 401, 429, 500) {
    ($client, $ua) = client('unit-secret private article', $status);
    my $error = caught(sub { $client->embed('query') });
    like "$error", qr/HTTP/, "HTTP $status reported";
    unlike "$error", qr/unit-secret|private/, 'no upstream body disclosed';
    is scalar @{$ua->{requests}}, 1, 'PoC fails without retries';
}

subtest 'only indexing input-length errors retry with shorter document values' => sub {
    my $input = JSON::PP->new->canonical->encode([
        {name => 'text', value => '本文😀' x 4000}, {name => 'title', value => '残すタイトル'},
    ]);
    my $too_long = {error => {type => 'invalid_request_error', code => undef,
        message => "This model's maximum context length is 8192 tokens, however you requested 10001 tokens (10001 in your prompt; 0 for the completion). private article"}};
    my ($c, $u) = client($too_long, 400);
    my $shorten = sub { MT::Plugin::Jev::Content->shorten_index_text(@_) };
    $u->{response} = sub { HTTP::Response->new(@{$u->{requests}} == 1 ? 400 : 200, 'Response', [],
        $json->encode(@{$u->{requests}} == 1 ? $too_long : body())) };
    is_deeply $c->embed($input, shorten => $shorten), [1, (0) x 3071], 'retry succeeds';
    is scalar @{$u->{requests}}, 2, 'one shortened retry';
    is $json->decode($u->{requests}[0]->content)->{input}, $input, 'first request uses full text';
    my $sent = $json->decode($u->{requests}[1]->content)->{input};
    cmp_ok length($sent), '<', length($input), 'retry payload is shorter';
    is(JSON::PP->new->decode($sent)->[1]{value}, '残すタイトル', 'title survived retry');
    is $c->token_usage->{requests}, 1, 'usage counts successful response only';

    ($c, $u) = client($too_long, 400);
    my $error = caught(sub { $c->embed($input, shorten => $shorten) });
    is scalar @{$u->{requests}}, 4, 'at most three shortened retries';
    is_deeply $error->{params}, [10001, 8192], 'safe token counts reported on exhaustion';
    unlike "$error", qr/private/, 'upstream message never disclosed';
    ($c, $u) = client($too_long, 400);
    $error = caught(sub { $c->embed('long search condition') });
    is scalar @{$u->{requests}}, 1, 'search query is never silently truncated';
    is_deeply $error->{params}, [10001, 8192], 'query length error includes token counts';
    ($c, $u) = client($too_long, 400);
    caught(sub { $c->embed($input, shorten => sub { $_[0] }) });
    is scalar @{$u->{requests}}, 1, 'no-progress shortening stops';
    for my $case ([400, {error => {message => 'Invalid request: private'}}], [401, $too_long],
        [429, $too_long], [500, $too_long], [400, {error => {message => []}}]) {
        ($c, $u) = client($case->[1], $case->[0]);
        caught(sub { $c->embed($input, shorten => sub { die 'Must not shorten unrelated errors' }) });
        is scalar @{$u->{requests}}, 1, 'unrelated error does not truncate or retry';
    }
};

($client, $ua) = client(body());
like ''.caught(sub { $client->embed(' ') }), qr/Enter text/, 'empty input rejected';
is scalar @{$ua->{requests}}, 0, 'empty input makes no call';
my $clock = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
my $now = 100;
$clock->redefine(time => sub { $now });
like ''.caught(sub { $client->embed('query', deadline => 99) }), qr/timed out/, 'deadline enforced';
$ua->{response} = sub { $now = 106; HTTP::Response->new(200, 'OK', [], $json->encode(body())) };
like ''.caught(sub { $client->embed('query', deadline => 105) }), qr/timed out/, 'late result rejected';
is $ua->{timeout}, 5, 'HTTP timeout shortened';
$now = 100;
($client, $ua) = client(body());
$ua->{response} = sub {
    my $first = @{$ua->{requests}} == 1;
    $now = $first ? 103 : 106;
    return HTTP::Response->new($first ? 400 : 200, 'Response', [], $json->encode($first
        ? {error => {message => 'maximum context length is 8192 tokens, however you requested 10001 tokens'}} : body()));
};
my $long_json = JSON::PP->new->encode([{name => 'text', value => '長い本文' x 3000}]);
like ''.caught(sub { $client->embed($long_json, deadline => 105,
    shorten => sub { MT::Plugin::Jev::Content->shorten_index_text(@_) }) }), qr/timed out/, 'shortened retries share original deadline';
is scalar @{$ua->{requests}}, 2, 'length failure permits one retry before deadline';
is $ua->{timeout}, 2, 'retry timeout uses remaining budget';
$ua->{response} = sub { die 'unit-secret transport details' };
like ''.caught(sub { $client->embed('query') }), qr/could not be reached/, 'transport details sanitized';
done_testing;
