package MT::Plugin::Jev::OpenAIClient;

use strict;
use warnings;
use JSON::PP ();
use HTTP::Request;
use Time::HiRes qw(time);
use MT::Plugin::Jev;

use constant ENDPOINT => 'https://api.openai.com/v1/embeddings';
use constant MODEL => 'text-embedding-3-large';
use constant DIMENSIONS => 3072;
use constant REQUEST_TIMEOUT => 10;

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
    return bless \%args, $class;
}

sub embed {
    my ($self, $text, %args) = @_;
    MT::Plugin::Jev::fail('Enter text to generate an embedding.') unless defined $text && $text =~ /\S/;
    my $deadline = $args{deadline} // time + REQUEST_TIMEOUT;
    MT::Plugin::Jev::fail('Natural-language search timed out.') if time >= $deadline;
    my $remaining = $deadline - time;
    $self->{ua}->timeout($remaining < REQUEST_TIMEOUT ? $remaining : REQUEST_TIMEOUT);
    my $json = JSON::PP->new->utf8;
    my $request = HTTP::Request->new('POST', ENDPOINT);
    $request->header('Authorization' => 'Bearer ' . $self->{api_key});
    $request->header('Content-Type' => 'application/json');
    $request->content($json->encode({model => MODEL, dimensions => DIMENSIONS,
        encoding_format => 'float', input => $text}));
    my $response = eval { $self->{ua}->request($request) };
    MT::Plugin::Jev::fail('Natural-language search timed out.') if time >= $deadline;
    MT::Plugin::Jev::fail('OpenAI could not be reached.') unless $response;
    MT::Plugin::Jev::fail('OpenAI returned HTTP [_1].', $response->code) unless $response->is_success;
    my $data = eval { $json->decode($response->content) };
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
    return $vector;
}

sub usage { $_[0]{usage} }

1;
