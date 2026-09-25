package MT::Plugin::Jev::Usage;

use strict;
use warnings;

my @tokens = qw(input_tokens output_tokens cached_input_tokens);

sub new { bless {requests => 0, map { $_ => 0 } @tokens}, $_[0] }

sub add {
    my ($self, $usage) = @_;
    return unless $usage->{requests};
    $self->{requests} += $usage->{requests};
    for my $name (@tokens) {
        my $value = $usage->{$name};
        # Missing usage must not look like zero-cost usage. Once a request
        # omits a count, the corresponding aggregate remains unknown.
        if (!defined $value || ref $value || $value !~ /\A\d+\z/) {
            $self->{$name} = undef;
        } elsif (defined $self->{$name}) {
            $self->{$name} += $value;
        }
    }
}

sub as_hash {
    my ($self) = @_;
    return {%$self, total_tokens => defined $self->{input_tokens} && defined $self->{output_tokens}
        ? $self->{input_tokens} + $self->{output_tokens} : undef};
}

1;
