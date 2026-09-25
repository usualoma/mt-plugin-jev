package MT::Plugin::Jev::Embedding;

use strict;
use warnings;
use base qw(MT::Object);
use MT::Plugin::Jev;
use MT::Plugin::Jev::Content;
use MT::Plugin::Jev::OpenAIClient;

use constant TEXT_VERSION => 1;

__PACKAGE__->install_properties({
    column_defs => {
        id => 'integer not null auto_increment',
        object_type => 'string(32) not null', object_id => 'integer not null',
        blog_id => 'integer not null', content_type_id => 'integer',
        source_hash => 'string(64) not null', model => 'string(64) not null',
        dimensions => 'integer not null', text_version => 'integer not null',
        vector => 'blob not null',
    },
    indexes => {
        object => {columns => ['object_type', 'object_id'], unique => 1},
        blog_id => 1, content_type_id => 1,
    },
    datasource => 'jev_embedding', primary_key => 'id',
});

sub type_of {
    my ($class, $object) = @_;
    return 'content_data' if $object->isa('MT::ContentData');
    return 'page' if $object->isa('MT::Page') || ($object->isa('MT::Entry') && $object->class eq 'page');
    return 'entry' if $object->isa('MT::Entry') && $object->class eq 'entry';
    return;
}

sub current {
    my ($self, $hash) = @_;
    return $self->source_hash eq $hash
        && $self->model eq MT::Plugin::Jev::OpenAIClient::MODEL
        && $self->dimensions == MT::Plugin::Jev::OpenAIClient::DIMENSIONS
        && $self->text_version == TEXT_VERSION;
}

sub normalized {
    my ($class, $vector) = @_;
    my $invalid = 'Invalid stored embedding. Rebuild the search index.';
    MT::Plugin::Jev::fail($invalid) unless ref $vector eq 'ARRAY'
        && @$vector == MT::Plugin::Jev::OpenAIClient::DIMENSIONS;
    my $norm = 0;
    for (@$vector) {
        MT::Plugin::Jev::fail($invalid) unless MT::Plugin::Jev::finite_number($_) && abs($_) <= 1;
        $norm += $_ * $_;
    }
    MT::Plugin::Jev::fail($invalid) unless $norm > 0;
    $norm = sqrt $norm;
    return [map { $_ / $norm } @$vector];
}

sub unpack_vector {
    my ($self) = @_;
    my $blob = $self->vector;
    my $invalid = 'Invalid stored embedding. Rebuild the search index.';
    MT::Plugin::Jev::fail($invalid)
        unless length($blob) == 4 * MT::Plugin::Jev::OpenAIClient::DIMENSIONS;
    # unpack already guarantees numeric scalars. Avoid millions of generic
    # type checks and number-to-string/regexp conversions on every search.
    my @vector = unpack('f<*', $blob);
    my $norm = 0;
    for (@vector) {
        # These comparisons also reject NaN and infinity.
        MT::Plugin::Jev::fail($invalid) unless $_ >= -1 && $_ <= 1;
        $norm += $_ * $_;
    }
    MT::Plugin::Jev::fail($invalid) unless $norm > 0;
    # Keep float32 rounding correction so cosine scores and ties stay intact.
    $norm = sqrt $norm;
    $_ /= $norm for @vector;
    return \@vector;
}

sub similarity {
    my ($class, $a, $b) = @_;
    my $score = 0;
    $score += $a->[$_] * $b->[$_] for 0 .. $#$a;
    return $score;
}

sub refresh {
    my ($class, $object, %args) = @_;
    my $type = $class->type_of($object) or return 'skipped';
    my $document = MT::Plugin::Jev::Content->index_document($object);
    my $terms = {object_type => $type, object_id => $object->id};
    my $saved = $class->load($terms);
    return 'skipped' if !$args{force} && $saved && $saved->current($document->{hash});
    $saved->remove or die $saved->errstr if $saved;
    return 'empty' unless length $document->{text};
    my $key = MT::Plugin::Jev::plugin()->get_config_value('openai_api_key', 'system');
    return 'unconfigured' unless $key;
    my $client = $args{client} || MT::Plugin::Jev::OpenAIClient->new(api_key => $key, debug => $args{debug});
    my $vector = $class->normalized($client->embed($document->{text},
        shorten => sub { MT::Plugin::Jev::Content->shorten_index_text(@_) }));
    my $index = $class->new;
    $index->set_values({%$terms, blog_id => $object->blog_id,
        content_type_id => $type eq 'content_data' ? $object->content_type_id : 0,
        source_hash => $document->{hash}, model => MT::Plugin::Jev::OpenAIClient::MODEL,
        dimensions => MT::Plugin::Jev::OpenAIClient::DIMENSIONS,
        text_version => TEXT_VERSION, vector => pack('f<*', @$vector)});
    $index->save or die $index->errstr;
    return 'generated';
}

sub remove_object {
    my ($class, $object) = @_;
    my $type = $class->type_of($object) or return;
    my $saved = $class->load({object_type => $type, object_id => $object->id});
    $saved->remove or die $saved->errstr if $saved;
    return 1;
}

1;
