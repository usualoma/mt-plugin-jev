package MT::Plugin::Jev;

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);

sub plugin { MT->component('Jev') }
sub translate { plugin()->translate(@_) }

sub fail {
    my ($phrase, @params) = @_;
    die bless { phrase => $phrase, params => \@params }, 'MT::Plugin::Jev::Error';
}

sub probability {
    my ($value) = @_;
    return 0 unless finite_number($value);
    return $value >= 0 && $value <= 1;
}

sub finite_number {
    my ($value) = @_;
    return defined $value && !ref $value && looks_like_number($value) && "$value" !~ /nan|inf/i;
}

sub validate_concurrency {
    my ($value) = @_;
    fail('The evaluation concurrency must be an integer from 1 to 10.')
        unless defined $value && !ref $value && $value =~ /\A(?:[1-9]|10)\z/;
    return $value;
}

sub validate_config {
    my ($config) = @_;
    fail('Select Jev or OpenAI as the evaluation provider.')
        unless defined $config->{jev_evaluator} && $config->{jev_evaluator} =~ /\A(?:jev|openai)\z/;
    fail('Enter a valid OpenAI evaluation model name.')
        unless defined $config->{openai_evaluation_model}
        && $config->{openai_evaluation_model} =~ /\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]{0,127}\z/;
    validate_concurrency($config->{jev_concurrency});
    fail('The token usage log setting must be 0 or 1.')
        if defined $config->{jev_log_usage}
        && (ref $config->{jev_log_usage} || $config->{jev_log_usage} !~ /\A[01]\z/);
    fail('The candidate limit must be an integer from 1 to 500.')
        unless defined $config->{jev_candidate_limit} && $config->{jev_candidate_limit} =~ /\A[1-9][0-9]{0,2}\z/
        && $config->{jev_candidate_limit} <= 500;
    fail('The Jev header search default must be 0 or 1.')
        if defined $config->{jev_header_default}
        && $config->{jev_header_default} !~ /\A[01]\z/;
    fail('The Jev match threshold must be a number from 0 to 1.')
        unless probability($config->{jev_threshold});
    fail('The Jev batch size must be an integer from 1 to 50.')
        unless defined $config->{jev_batch_size}
        && $config->{jev_batch_size} =~ /\A[1-9][0-9]?\z/
        && $config->{jev_batch_size} <= 50;
    fail('Enter a valid Jev model name.')
        unless defined $config->{jev_model}
        && $config->{jev_model} =~ /\A[a-zA-Z0-9][a-zA-Z0-9._\/-]{0,127}\z/;
    fail('Enter a valid TypeSafe API key.')
        if defined $config->{jev_api_key}
        && $config->{jev_api_key} =~ /[^\x21-\x7e]/;
    fail('Enter a valid OpenAI API key.')
        if defined $config->{openai_api_key} && $config->{openai_api_key} =~ /[^\x21-\x7e]/;
    return $config;
}

sub config {
    return validate_config(plugin()->get_config_hash('system'));
}

package MT::Plugin::Jev::Error;
use overload '""' => sub { $_[0]->{phrase} }, fallback => 1;
sub message { MT::Plugin::Jev::translate($_[0]->{phrase}, @{ $_[0]->{params} }) }

1;
