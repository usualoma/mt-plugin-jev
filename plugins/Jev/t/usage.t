use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP;
use MT::Plugin::Jev::Usage;

my $usage = MT::Plugin::Jev::Usage->new;
is_deeply $usage->as_hash, {requests => 0, input_tokens => 0, output_tokens => 0,
    cached_input_tokens => 0, total_tokens => 0}, 'no API requests means zero usage';
$usage->add({requests => 1, input_tokens => 100, output_tokens => 10, cached_input_tokens => 64});
$usage->add({requests => 2, input_tokens => 200, output_tokens => 20, cached_input_tokens => 128});
is_deeply $usage->as_hash, {requests => 3, input_tokens => 300, output_tokens => 30,
    cached_input_tokens => 192, total_tokens => 330}, 'cache count is a subset of input, not added twice';

for my $invalid (undef, -1, 'NaN', 'private-content', 1.5, [], JSON::PP::true) {
    my $partial = MT::Plugin::Jev::Usage->new;
    $partial->add({requests => 1, input_tokens => $invalid, output_tokens => 2, cached_input_tokens => 0});
    $partial->add({requests => 1, input_tokens => 50, output_tokens => 3, cached_input_tokens => 0});
    is_deeply $partial->as_hash, {requests => 2, input_tokens => undef, output_tokens => 5,
        cached_input_tokens => 0, total_tokens => undef}, 'missing or invalid counts stay unknown after later valid usage';
    my $parent = MT::Plugin::Jev::Usage->new;
    $parent->add($partial->as_hash);
    is_deeply $parent->as_hash, $partial->as_hash, 'unknown counts survive worker aggregation';
}

done_testing;
