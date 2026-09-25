package MT::Plugin::Jev::OpenAIClient;

use strict;
use warnings;
use JSON::PP ();
use Encode qw(decode encode_utf8);
use HTTP::Request;
use Time::HiRes qw(time);
use MT::Plugin::Jev;
use MT::Plugin::Jev::Usage;

use constant ENDPOINT => 'https://api.openai.com/v1/embeddings';
use constant MODEL => 'text-embedding-3-large';
use constant DIMENSIONS => 3072;
use constant REQUEST_TIMEOUT => 10;
use constant MAX_SHORTEN_RETRIES => 3;

sub new {
    my ($class, %args) = @_;
    unless ($args{ua}) {
        require LWP::UserAgent;
        $args{ua} = LWP::UserAgent->new(
            agent => 'MovableType-Jev/0.2', max_redirect => 0,
            protocols_allowed => ['https'],
        );
        $args{ua}->env_proxy;
    }
    return bless {%args, token_usage => MT::Plugin::Jev::Usage->new}, $class;
}

sub embed {
    my ($self, $text, %args) = @_;
    MT::Plugin::Jev::fail('Enter text to generate an embedding.') unless defined $text && $text =~ /\S/;
    my $deadline = $args{deadline} // time + REQUEST_TIMEOUT;
    my $json = JSON::PP->new->utf8;
    my $data;
    for my $attempt (0 .. MAX_SHORTEN_RETRIES) {
        MT::Plugin::Jev::fail('Natural-language search timed out.') if time >= $deadline;
        my $remaining = $deadline - time;
        $self->{ua}->timeout($remaining < REQUEST_TIMEOUT ? $remaining : REQUEST_TIMEOUT);
        my $request = HTTP::Request->new('POST', ENDPOINT);
        $request->header('Authorization' => 'Bearer ' . $self->{api_key});
        $request->header('Content-Type' => 'application/json');
        $request->content($json->encode({model => MODEL, dimensions => DIMENSIONS,
            encoding_format => 'float', input => $text}));
        $self->_debug({event => 'embedding_request', attempt => $attempt + 1,
            endpoint => ENDPOINT, model => MODEL, dimensions => DIMENSIONS,
            input_chars => length($text), input_bytes => length(encode_utf8($text)),
            request_bytes => length($request->content), shortening_enabled => $args{shorten} ? 1 : 0})
            if $self->{debug};
        my $response = eval { $self->{ua}->request($request) };
        my $transport_error = $@;
        $self->_debug({event => 'embedding_transport_error', attempt => $attempt + 1,
            error => "$transport_error"}) if $self->{debug} && !$response;
        MT::Plugin::Jev::fail('Natural-language search timed out.') if time >= $deadline;
        MT::Plugin::Jev::fail('OpenAI could not be reached.') unless $response;
        $data = eval { $json->decode($response->content) };
        my $decoded = $@ ? 0 : 1;
        if ($self->{debug}) {
            my $record = {event => 'embedding_response', attempt => $attempt + 1,
                status => 0 + $response->code, request_id => scalar $response->header('x-request-id'),
                content_type => scalar $response->header('Content-Type'),
                content_encoding => scalar $response->header('Content-Encoding'),
                response_bytes => length($response->content), json_decoded => $decoded ? 1 : 0};
            unless ($response->is_success) {
                # Decode content encoding for diagnostics only. Leave response
                # handling unchanged until the actual failure is understood.
                my $body = eval { $response->decoded_content(charset => 'none') };
                $body = $response->content unless defined $body;
                $record->{response_body} = decode('UTF-8', $body);
            }
            $self->_debug($record);
        }
        last if $response->is_success;
        my ($limit, $tokens) = $response->code == 400 ? _context_tokens($data) : ();
        if ($limit && $args{shorten} && $attempt < MAX_SHORTEN_RETRIES) {
            # Some context-length errors report only the limit. Halve in
            # that case; otherwise use the token ratio with headroom.
            my $ratio = defined $tokens ? 0.97 * $limit / $tokens : 0.5;
            $ratio = 0.95 if $ratio > 0.95;
            my $shorter = $args{shorten}->($text, $ratio);
            if (defined $shorter && length($shorter) < length($text)) {
                $self->_debug({event => 'embedding_retry', attempt => $attempt + 1,
                    context_limit => $limit, input_tokens => $tokens, ratio => $ratio,
                    input_chars => length($text), next_input_chars => length($shorter)})
                    if $self->{debug};
                $text = $shorter;
                next;
            }
        }
        MT::Plugin::Jev::fail('OpenAI embedding input has [_1] tokens; the maximum is [_2].', $tokens, $limit)
            if defined $tokens;
        MT::Plugin::Jev::fail('OpenAI embedding input exceeds the maximum of [_1] tokens.', $limit)
            if $limit;
        MT::Plugin::Jev::fail('OpenAI returned HTTP [_1].', $response->code);
    }
    my $invalid = 'OpenAI returned an invalid embedding.';
    MT::Plugin::Jev::fail($invalid) unless ref $data eq 'HASH'
        && ($data->{model} || '') eq MODEL && ref $data->{data} eq 'ARRAY'
        && @{ $data->{data} } == 1 && ref $data->{data}[0] eq 'HASH'
        && defined $data->{data}[0]{index} && $data->{data}[0]{index} eq '0'
        && ($data->{data}[0]{object} || '') eq 'embedding';
    my $vector = $data->{data}[0]{embedding};
    MT::Plugin::Jev::fail($invalid) unless ref $vector eq 'ARRAY' && @$vector == DIMENSIONS;
    my $norm = 0;
    for (@$vector) {
        MT::Plugin::Jev::fail($invalid) unless MT::Plugin::Jev::finite_number($_) && abs($_) <= 1;
        $norm += $_ * $_;
    }
    MT::Plugin::Jev::fail($invalid) unless $norm > 0;
    $self->{usage} = $data->{usage};
    my $usage = ref $data->{usage} eq 'HASH' ? $data->{usage} : {};
    $self->{token_usage}->add({requests => 1, input_tokens => $usage->{prompt_tokens},
        output_tokens => 0, cached_input_tokens => 0});
    return $vector;
}

sub _debug {
    my ($self, $record) = @_;
    return unless $self->{debug};
    # Keys can appear in upstream error messages. Redact before truncating
    # so even a key straddling the preview boundary stays hidden.
    for my $name (keys %$record) {
        next unless defined $record->{$name} && !ref $record->{$name};
        $record->{$name} =~ s/\Q$self->{api_key}\E/[REDACTED]/g if length($self->{api_key} || '');
        $record->{$name} =~ s/\bsk-[A-Za-z0-9_-]+/[REDACTED]/g;
        if (length($record->{$name}) > 4096) {
            $record->{$name} = substr($record->{$name}, 0, 4096) . ' [truncated]';
        }
    }
    $self->{debug}->($record);
}

sub _context_tokens {
    my ($data) = @_;
    return unless ref $data eq 'HASH' && ref $data->{error} eq 'HASH';
    my $message = $data->{error}{message};
    return unless defined $message && !ref $message
        && $message =~ /\bmaximum context length is ([1-9][0-9]{0,8}) tokens\b/;
    my $limit = 0 + $1;
    my ($tokens) = $message =~ /\brequested ([1-9][0-9]{0,8}) tokens\b/;
    return if defined $tokens && $tokens <= $limit;
    return ($limit, defined $tokens ? 0 + $tokens : undef);
}

sub usage { $_[0]{usage} }
sub token_usage { $_[0]{token_usage}->as_hash }

1;
