package MT::Plugin::Jev::Search;

use strict;
use warnings;
use Time::HiRes qw(time);
use MT::Plugin::Jev;
use MT::Plugin::Jev::Client;
use MT::Plugin::Jev::Content;
use MT::Plugin::Jev::Embedding;
use MT::Plugin::Jev::OpenAIClient;
use MT::Plugin::Jev::OpenAIEvaluator;

sub run {
    my ($class, $app, $config, $type, $condition, $original) = @_;
    require MT::CMS::Search;
    my $client = $config->{jev_evaluator} eq 'openai'
        ? MT::Plugin::Jev::OpenAIEvaluator->new(api_key => $config->{openai_api_key},
            model => $config->{openai_evaluation_model}, concurrency => $config->{jev_concurrency})
        : MT::Plugin::Jev::Client->new(api_key => $config->{jev_api_key}, model => $config->{jev_model},
            concurrency => $config->{jev_concurrency});
    my $deadline = time + $client->search_timeout;
    my $api = $app->registry('search_apis')->{$type};
    my $original_iter = \&MT::CMS::Search::incremental_iter;

    # Request-local adapters preserve core's scope and renderer, including
    # custom terms/args paths that do not call make_terms.
    no warnings qw(redefine once);
    local *MT::CMS::Search::make_terms = sub { return [] };
    local *MT::CMS::Search::incremental_iter = sub {
        my $iter = $original_iter->(@_);
        return _matching_iter($app, $iter, $client, $deadline, $api, $type, $condition, $config);
    };
    return $original->($app);
}

sub _matching_iter {
    my ($app, $iter, $client, $deadline, $api, $type, $condition, $config) = @_;
    my (@top, $query, $eligible);
    my $check = $app->handler_to_coderef($api->{perm_check});
    my $embedding = MT->model('jev_embedding');
    my $openai = MT::Plugin::Jev::OpenAIClient->new(api_key => $config->{openai_api_key});
    while (1) {
        my @objects;
        while (@objects < 100) {
            $client->check_deadline($deadline);
            my $object = $iter->() or last;
            next unless $app->user->is_superuser || ($check && $check->($object));
            push @objects, $object;
        }
        last unless @objects;
        $eligible += @objects;
        my %indexes = map { $_->object_id => $_ } $embedding->load({
            object_type => $type, object_id => [map { $_->id } @objects],
        });
        for my $object (@objects) {
            $client->check_deadline($deadline);
            my $index = $indexes{$object->id} or next;
            my $document = MT::Plugin::Jev::Content->index_document($object, $api);
            next unless $index->current($document->{hash});
            $query ||= $embedding->normalized($openai->embed($condition, deadline => $deadline));
            my $similarity = $embedding->similarity($query, $index->unpack_vector);
            push @top, {object => $object, similarity => $similarity};
            @top = sort { $b->{similarity} <=> $a->{similarity}
                || $a->{object}->id <=> $b->{object}->id } @top;
            pop @top if @top > $config->{jev_candidate_limit};
        }
    }
    MT::Plugin::Jev::fail('Generate the search index with tools/Jev/build-index before searching.')
        if $eligible && !@top;
    my (@batches, @evaluated, @matches);
    while (@top) {
        my @batch = splice @top, 0, $config->{jev_batch_size};
        my @candidates;
        for my $item (@batch) {
            my $object = $item->{object};
            next unless $app->user->is_superuser || ($check && $check->($object));
            push @candidates, {id => $type . '_' . $object->id,
                fields => MT::Plugin::Jev::Content->fields($app, $object,
                    MT::Plugin::Jev::Content->columns($object, $api), $api)};
        }
        next unless @candidates;
        push @batches, \@candidates;
        push @evaluated, @batch;
    }
    my $scores = $client->evaluate_batches(condition => $condition,
        batches => \@batches, deadline => $deadline);
    $client->check_deadline($deadline);
    for my $item (@evaluated) {
        my $score = $scores->{$type . '_' . $item->{object}->id};
        $client->invalid_answer
            unless ref $score eq 'HASH' && MT::Plugin::Jev::probability($score->{noul})
            && MT::Plugin::Jev::finite_number($score->{score}) && $score->{score} >= 0 && $score->{score} <= 4;
        next if $score->{noul} < $config->{jev_threshold};
        $item->{score} = $score->{score};
        push @matches, $item;
    }
    @matches = sort { $b->{score} <=> $a->{score} || $b->{similarity} <=> $a->{similarity}
        || $a->{object}->id <=> $b->{object}->id } @matches;
    return sub {
        $client->check_deadline($deadline);
        my $item = shift @matches;
        return $item ? $item->{object} : undef;
    };
}

1;
