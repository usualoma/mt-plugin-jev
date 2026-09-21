use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use Test::MockModule;
use MT::Test::Permission;
use MT::Test::App qw(MT::Test::Role::CMS::Search);
use MT::Plugin::Jev::Client;
use MT::Plugin::Jev::OpenAIClient;
use MT::Plugin::Jev::Embedding;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');

my $openai = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
my @embedded;
$openai->redefine(embed => sub { push @embedded, $_[1]; return [1, (0) x 3071] });
my $plugin = MT->component('Jev');
ok $plugin, 'Jev registered';
$plugin->set_config_value({ openai_api_key => 'openai-test', jev_candidate_limit => 50, jev_api_key => 'test-key', jev_model => 'jev-latest', jev_threshold => 0.5, jev_batch_size => 2 }, 'system');

my $admin = MT->model('author')->load(1);
my $site = MT::Test::Permission->make_website(name => 'Jev test site');
my $entry = MT::Test::Permission->make_entry(
    blog_id => $site->id, title => '導入の記録', text => '<p>設定に苦労しました。</p>',
);
my $other = MT::Test::Permission->make_entry(blog_id => $site->id, title => 'Weather', text => 'Sunny');
my (@sent, @batches);
my %ranking;
my %wanted = ('entry_' . $entry->id => 0.8);
my $failure;
my $mock = Test::MockModule->new('MT::Plugin::Jev::Client');
$mock->redefine(evaluate_batches => sub {
    my ($self, %args) = @_;
    my %answers;
    for my $batch (@{$args{batches}}) {
        push @batches, $batch;
        MT::Plugin::Jev::fail('Jev could not be reached. The search did not complete.')
            if $failure && @batches >= $failure;
        push @sent, @$batch;
        $answers{$_->{id}} = {noul => ($wanted{$_->{id}} // 0.1), score => ($ranking{$_->{id}} // 3)} for @$batch;
    }
    return \%answers;
});

my $app = MT::Test::App->new('MT::App::CMS');
$app->login($admin);
$app->get_ok({ __mode => 'search_replace', blog_id => $site->id, _type => 'entry' });
ok !$app->generic_error, 'initial screen';
ok $app->wq_find('#is_jev')->size, 'Jev option rendered';
is scalar @sent, 0, 'opening screen does not call Jev';
$app->search('導入後に困ったことが書かれている記事', { is_jev => 1 });
ok !$app->generic_error, 'Jev search succeeds' or diag $app->generic_error;
is scalar @sent, 2, 'literal text does not restrict candidates';
like $app->content, qr/導入の記録/, 'matching entry shown';
unlike $app->content, qr/>Weather</, 'nonmatching entry omitted';
ok $app->wq_find('#is_jev')->attr('checked'), 'Jev stays selected';
ok !$app->wq_find('#replace-button')->size, 'replacement unavailable';

sub request {
    my (%args) = @_;
    @sent = (); @batches = ();
    $app->get_ok({__mode => 'search_replace', blog_id => $site->id, _type => 'entry',
        search => '導入後に困った記事', do_search => 1, is_jev => 1, %args});
}
sub sent_ids { [sort map { $_->{id} } @sent] }

subtest 'header POST runs Jev immediately and unchecked requests stay standard' => sub {
    @sent = (); @batches = ();
    $app->post_ok({__mode => 'search_replace', blog_id => $site->id, _type => 'entry',
        object_type => 'entry', content_type_id => '', search => '導入後に困った記事',
        do_search => 1, is_jev => 1});
    ok !$app->generic_error, 'header search succeeds';
    is scalar @sent, 2, 'header search immediately evaluates candidates';
    ok $app->wq_find('#is_jev')->attr('checked'), 'result screen keeps Jev checked';
    like $app->content, qr/導入の記録/, 'natural-language match displayed';
    @sent = (); @batches = ();
    $app->post_ok({__mode => 'search_replace', blog_id => $site->id, _type => 'entry',
        object_type => 'entry', search => 'Weather', do_search => 1});
    ok !$app->generic_error, 'unchecked header search succeeds';
    is scalar @sent, 0, 'default ON does not override unchecked header request';
    like $app->content, qr/>Weather</, 'unchecked request uses literal search';
    request(quicksearch => 1);
    is scalar @sent, 2, 'legacy header quicksearch also evaluates full candidates';
};

subtest 'normal search and replacement are unchanged' => sub {
    request(is_jev => 0, search => 'Weather');
    is scalar @sent, 0, 'normal search makes no API calls';
    like $app->content, qr/>Weather</, 'standard text search works after Jev search';
    ok $app->wq_find('#replace-button')->size, 'standard replacement is available';
    $app->replace('Fine day', [$other->id]);
    ok !$app->generic_error, 'normal replacement succeeds';
    $other = MT->model('entry')->load($other->id);
    is($other->title, 'Fine day', 'standard replacement updated selected entry');
};

subtest 'field selection and incompatible options' => sub {
    request(is_limited => 1, search_cols => ['text'], is_regex => 1, case => 1, search => '[');
    ok !$app->generic_error, 'regex syntax is treated as a natural-language condition';
    is_deeply [map { $_->{name} } @{ $sent[0]{fields} }], [qw(basename excerpt keywords text text_more title)], 'natural-language search always uses all fields';
    my ($candidate) = grep { $_->{id} eq 'entry_' . $entry->id } @sent;
    my ($body_field) = grep { $_->{name} eq 'text' } @{$candidate->{fields}};
    is $body_field->{value}, '設定に苦労しました。', 'body is readable text';
    is $app->{_app}->param('is_regex'), 1, 'request regex parameter restored after success';
    is $app->{_app}->param('case'), 1, 'request case parameter restored after success';
    ok !$app->{_app}->param('show_all'), 'internal show-all flag restored after success';
    request(is_limited => 1, search_cols => ['password']);
    ok !$app->generic_error, 'obsolete field selection is ignored';
    is scalar @sent, 2, 'all indexed documents evaluated';
};

subtest 'date, status and child site scope precede API calls' => sub {
    $entry->authored_on('20260921090000'); $entry->status(2); $entry->save or die $entry->errstr;
    $other->authored_on('20200101000000'); $other->status(1); $other->save or die $other->errstr;
    my $child = MT::Test::Permission->make_blog(parent_id => $site->id);
    my $child_entry = MT::Test::Permission->make_entry(blog_id => $child->id, title => 'Child content');
    my $elsewhere = MT::Test::Permission->make_website;
    my $foreign = MT::Test::Permission->make_entry(blog_id => $elsewhere->id, title => 'Different site');
    request(is_dateranged => 1, from => '2026-09-21', to => '2026-09-21', publish_status => 2);
    is_deeply sent_ids(), ['entry_' . $entry->id], 'date and publication state applied before Jev';
    request();
    is_deeply sent_ids(), [sort map { 'entry_' . $_->id } ($entry, $other, $child_entry)], 'parent site includes child and excludes unrelated site';
    request(blog_id => $child->id);
    is_deeply sent_ids(), ['entry_' . $child_entry->id], 'child site scope excludes parent';
};

subtest 'display limit counts matches and show all keeps Jev' => sub {
    $wanted{'entry_' . $other->id} = 0.5;
    request(limit => 1);
    ok $app->wq_find('#have-more-count')->size, 'one extra match signals more results';
    like $app->wq_find('#have-more-count')->text, qr/first 1 results/, 'limit is a matching-record limit';
    $app->search('導入後に困った記事', {is_jev => 1, limit => 'all'});
    ok !$app->generic_error, 'show all succeeds';
    ok !$app->wq_find('#have-more-count')->size, 'complete result has no more link';
    like $app->wq_find('#result-count')->text, qr/2 results/, 'all matches, including threshold boundary, shown';
    ok $app->wq_find('#is_jev')->attr('checked'), 'show all retains Jev';
    delete $wanted{'entry_' . $other->id};
};

subtest 'errors discard partial results and restore standard search' => sub {
    require MT::CMS::Search;
    my $make_terms = \&MT::CMS::Search::make_terms;
    my $iter = \&MT::CMS::Search::incremental_iter;
    $failure = 2;
    request(case => 1, is_regex => 1, quicksearch => 1);
    like $app->generic_error, qr/search did not complete/, 'failure reported';
    ok !$app->wq_find('#result-count')->size, 'partial result count not displayed';
    ok !$app->wq_find('#have-more-count')->size, 'failure does not look like a successful limited search';
    is \&MT::CMS::Search::make_terms, $make_terms, 'query adapter restored';
    is \&MT::CMS::Search::incremental_iter, $iter, 'iterator restored';
    is $app->{_app}->param('case'), 1, 'request case parameter restored after error';
    is $app->{_app}->param('is_regex'), 1, 'request regex parameter restored after error';
    is $app->{_app}->param('quicksearch'), 1, 'request quicksearch parameter restored after error';
    ok !$app->{_app}->param('show_all'), 'internal show-all flag restored after error';
    $failure = undef;
    request(is_jev => 0, search => '導入');
    is scalar @sent, 0, 'normal search after failure makes no API calls';
    ok !$app->generic_error, 'normal search after failure succeeds';
    request(search => '  ');
    like $app->generic_error, qr/Enter a natural-language/, 'empty condition rejected';
    is scalar @sent, 0, 'empty condition not sent';
    request(do_replace => 1, replace => 'danger', replace_ids => $entry->id);
    like $app->generic_error, qr/Replacement is unavailable/, 'forged replacement refused';
    is(MT->model('entry')->load($entry->id)->title, '導入の記録', 'Jev never replaces content');
    $plugin->set_config_value('jev_api_key', '', 'system');
    request();
    like $app->generic_error, qr/Configure a TypeSafe API key/, 'missing key is actionable';
    is scalar @sent, 0, 'missing key makes no API calls';
    $plugin->set_config_value('jev_api_key', 'test-key', 'system');
};

subtest 'OpenAI evaluator uses its key and model, and renders the selected destination' => sub {
    my $evaluator = Test::MockModule->new('MT::Plugin::Jev::OpenAIEvaluator');
    my $calls = 0;
    $evaluator->redefine(evaluate_batches => sub {
        my ($self, %args) = @_;
        $calls++;
        is $self->{api_key}, 'openai-test', 'embedding key shared for evaluation';
        is $self->{model}, 'gpt-4.1-mini', 'chosen OpenAI model used';
        is $self->{concurrency}, 5, 'evaluation concurrency shared';
        cmp_ok $args{deadline} - Time::HiRes::time(), '>', 100, 'OpenAI receives longer search deadline';
        return {map { $_->{id} => {noul => $wanted{$_->{id}} // 0.1, score => 3} } map { @$_ } @{$args{batches}}};
    });
    $plugin->set_config_value({jev_evaluator => 'openai', openai_evaluation_model => 'gpt-4.1-mini', jev_api_key => ''}, 'system');
    request();
    ok !$app->generic_error, 'OpenAI search works without TypeSafe key';
    is $calls, 1, 'OpenAI evaluator called';
    is scalar @sent, 0, 'Jev evaluator never called';
    like $app->content, qr/導入の記録/, 'OpenAI match shown';
    unlike $app->content, qr/>Weather</, 'OpenAI nonmatch omitted';
    like $app->wq_find('#jev-search-hint')->text, qr/candidate content are sent to OpenAI/, 'actual destination shown';
    $plugin->set_config_value('openai_api_key', '', 'system');
    request();
    like $app->generic_error, qr/Configure an OpenAI API key/, 'OpenAI key is required';
    is $calls, 1, 'missing key does not call evaluator';
    $plugin->set_config_value('openai_api_key', 'openai-test', 'system');
    $evaluator->redefine(evaluate_batches => sub { $_[0]->invalid_answer });
    request();
    like $app->generic_error, qr/OpenAI returned an invalid or incomplete/, 'OpenAI failure identified';
    unlike $app->content, qr/>Weather</, 'failure does not expose partial results';
    is scalar @sent, 0, 'OpenAI failure never falls back to Jev';
    $plugin->set_config_value({jev_evaluator => 'jev', jev_api_key => 'test-key'}, 'system');
    request();
    ok !$app->generic_error, 'switching back restores Jev search';
    ok scalar @sent, 'Jev called again';
    like $app->wq_find('#jev-search-hint')->text, qr/candidate content is sent to TypeSafe/, 'TypeSafe destination restored';
};

subtest 'permissions are checked before content leaves MT' => sub {
    my $writer = MT::Test::Permission->make_author(name => 'jev_writer');
    my $role = MT::Test::Permission->make_role(name => 'Jev writer', permissions => "'create_post'");
    require MT::Association;
    MT::Association->link($writer => $role => $site);
    my $own = MT::Test::Permission->make_entry(blog_id => $site->id, author_id => $writer->id, title => 'My draft', status => 1);
    $plugin->set_config_value('jev_candidate_limit', 1, 'system');
    $app->login($writer);
    request();
    ok !$app->generic_error, 'writer may search own content' or diag $app->generic_error;
    is_deeply sent_ids(), ['entry_' . $own->id], 'other authors and child-site content never sent';
    request(blog_id => 0);
    is_deeply sent_ids(), [], 'writer without system search permission sends no content';
    $app->has_permission_error;
    $app->login($admin);
    $plugin->set_config_value('jev_candidate_limit', 50, 'system');
};

subtest 'page tab uses the same predicate and preserves selection' => sub {
    my $page = MT::Test::Permission->make_page(blog_id => $site->id, title => 'Jev page', text => 'A page body');
    $wanted{'page_' . $page->id} = 0.8;
    request();
    @sent = ();
    $app->change_tab('page');
    ok !$app->generic_error, 'page tab search succeeds';
    is_deeply sent_ids(), ['page_' . $page->id], 'only pages sent';
    ok $app->wq_find('#is_jev')->attr('checked'), 'tab change keeps Jev';
    like $app->content, qr/>Jev page</, 'matching page shown';
};

subtest 'content data fields, labels, types and date indexes' => sub {
    my $ct = MT::Test::Permission->make_content_type(blog_id => $site->id, name => 'Jev records');
    my @definitions = (
        ['Title', 'single_line_text'], ['Body', 'multi_line_text'],
        ['Date', 'date_and_time'], ['Choices', 'checkboxes'], ['Items', 'list'], ['Table', 'tables'],
    );
    my (@fields, @defs);
    for my $definition (@definitions) {
        my ($name, $type) = @$definition;
        my $field = MT::Test::Permission->make_content_field(blog_id => $site->id, content_type_id => $ct->id, name => $name, type => $type);
        push @fields, $field;
        push @defs, { id => $field->id, name => $name, unique_id => $field->unique_id,
            type => $type, order => scalar @fields, options => {label => $name,
                ($type eq 'checkboxes' ? (values => [{value => 'r', label => '赤'}, {value => 'b', label => '青'}]) : ())} };
    }
    $ct->fields(\@defs);
    $ct->data_label($fields[0]->unique_id);
    $ct->save or die $ct->errstr;
    my $record = MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $ct->id,
        data => {$fields[0]->id => 'Jev content label', $fields[1]->id => '<p>導入に困った。</p>',
            $fields[2]->id => '20260921090000', $fields[3]->id => ['r'], $fields[4]->id => ['A', 'B'],
            $fields[5]->id => '<tr><td>first</td><td>second</td></tr>'});
    my $old_record = MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $ct->id,
        data => {$fields[0]->id => 'Old record', $fields[1]->id => '昔の本文', $fields[2]->id => '20200101000000'});
    my $other_ct = MT::Test::Permission->make_content_type(blog_id => $site->id, name => 'Other records');
    my $other_field = MT::Test::Permission->make_content_field(blog_id => $site->id, content_type_id => $other_ct->id, name => 'Private title');
    $other_ct->fields([{id => $other_field->id, name => 'Private title', unique_id => $other_field->unique_id,
        type => 'single_line_text', order => 1, options => {label => 'Private title'}}]);
    $other_ct->save or die $other_ct->errstr;
    MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $other_ct->id, data => {$other_field->id => 'Other type text'});
    $wanted{'content_data_' . $record->id} = 0.9;
    # CMS normally restarts after a content type is created. This test adds
    # fixtures after its first request, so refresh the same core definitions.
    require MT::CMS::ContentType;
    MT::CMS::ContentType::init_content_type(undef, MT->app);

    request(_type => 'content_data', content_type_id => $ct->id);
    ok !$app->generic_error, 'content data search succeeds' or diag $app->generic_error;
    is_deeply sent_ids(), [sort map { 'content_data_' . $_->id } ($record, $old_record)], 'only chosen content type evaluated';
    my ($sent) = grep { $_->{id} eq 'content_data_' . $record->id } @sent;
    my %values = map { $_->{name} => $_->{value} } @{ $sent->{fields} };
    is $values{label}, 'Jev content label', 'data label resolved from its field';
    is $values{'__field:' . $fields[1]->id}, '導入に困った。', 'HTML content field converted';
    is_deeply $values{'__field:' . $fields[3]->id}, [{value => 'r', label => '赤'}], 'selection has its readable label';
    is_deeply $values{'__field:' . $fields[4]->id}, ['A', 'B'], 'list values preserved';
    ok !exists $values{'__field:' . $fields[5]->id}, 'table field excluded because MT does not mark it searchable';
    ok !exists $values{'__field:' . $other_field->id}, 'other type fields excluded';
    like $app->content, qr/>Jev content label</, 'matching content data displayed';

    request(_type => 'content_data', content_type_id => $ct->id, is_limited => 1, search_cols => ['__field:' . $fields[1]->id]);
    ok scalar(@{$sent[0]{fields}}) > 1, 'content data also ignores field selection';
    request(_type => 'content_data', content_type_id => $ct->id, is_dateranged => 1,
        date_time_field_id => $fields[2]->id, from => '2026-09-21', to => '2026-09-21');
    is_deeply sent_ids(), ['content_data_' . $record->id], 'content-field date index filters before Jev';

    request(_type => 'content_data', content_type_id => $ct->id, is_limited => 1, search_cols => ['__field:' . $other_field->id]);
    ok !$app->generic_error, 'cross-type field selection is ignored';
    is scalar @sent, 2, 'current type is still evaluated';
};

subtest 'regexp setting and repeated initialization' => sub {
    $MT::Plugin::Jev::Test::env->update_config(DisableRegexpSearch => 1);
    request();
    ok !$app->generic_error, 'Jev works when regular expression search is disabled';
    ok scalar @sent, 'candidates still evaluated';
    $MT::Plugin::Jev::Test::env->update_config(DisableRegexpSearch => 0);
    my $wrapper = \&MT::CMS::Search::search_replace;
    MT::Plugin::Jev::CMS::init_app();
    is \&MT::CMS::Search::search_replace, $wrapper, 'wrapper installed only once';
    request(_type => 'asset');
    like $app->generic_error, qr/Jev supports entries/, 'unsupported type refused';
    is scalar @sent, 0, 'unsupported type never sent';
};

subtest 'no matches is a completed search' => sub {
    $plugin->set_config_value('jev_threshold', 1, 'system');
    request();
    like $app->content, qr/No entries were found that match the given criteria/, 'standard no-matches message shown';
    ok scalar @sent, 'candidates were actually evaluated';
    ok !$app->wq_find('#have-more-count')->size, 'no more-results link';
    $plugin->set_config_value('jev_threshold', 0.5, 'system');
};


subtest 'top-K is chosen before reranking; Score decides final order' => sub {
    my $rank_site = MT::Test::Permission->make_website(name => 'Ranking');
    my @entries = map { MT::Test::Permission->make_entry(blog_id => $rank_site->id,
        title => "Ranking $_", authored_on => "2026092${_}090000") } 1..4;
    # All vectors tie: candidate selection must use ID, not core date order.
    $plugin->set_config_value('jev_candidate_limit', 3, 'system');
    $wanted{'entry_' . $_->id} = 0.9 for @entries;
    $ranking{'entry_' . $entries[0]->id} = 2;
    $ranking{'entry_' . $entries[1]->id} = 4;
    $ranking{'entry_' . $entries[2]->id} = 4;
    $wanted{'entry_' . $entries[2]->id} = 0.1;
    @embedded = ();
    request(blog_id => $rank_site->id, limit => 1);
    is_deeply sent_ids(), [sort map { 'entry_' . $_->id } @entries[0..2]], 'only vector top three sent despite result limit';
    is scalar @embedded, 1, 'one query embedding per search, no document embeddings';
    like $app->content, qr/>Ranking 2</, 'Score promotes the second candidate';
    unlike $app->content, qr/>Ranking 1</, 'display limit applied after Score order';
    request(blog_id => $rank_site->id, limit => 'all');
    unlike $app->content, qr/>Ranking 3</, 'high Score cannot override failed condition';
    unlike $app->content, qr/>Ranking 4</, 'no expansion beyond top-K';
    my @vectors = ([1, 0], [0.6, 0.8], [0.8, 0.6], [-1, 0]);
    for my $i (0 .. $#entries) {
        my $index = MT->model('jev_embedding')->load({object_type => 'entry', object_id => $entries[$i]->id});
        $index->vector(pack('f<*', @{$vectors[$i]}, (0) x 3070));
        $index->save or die $index->errstr;
    }
    $plugin->set_config_value('jev_candidate_limit', 2, 'system');
    $wanted{'entry_' . $entries[2]->id} = 0.9;
    $ranking{'entry_' . $entries[2]->id} = 2;
    request(blog_id => $rank_site->id, limit => 'all');
    is_deeply sent_ids(), [sort map { 'entry_' . $_->id } @entries[0, 2]], 'known vector similarities choose top-K independently of Score and date';
    like $app->content, qr/>Ranking 1<.*>Ranking 3</s, 'equal Scores use vector similarity before core date order';
    $plugin->set_config_value('jev_candidate_limit', 50, 'system');
};

subtest 'missing and stale indexes do not trigger generation during search' => sub {
    my $unindexed_site = MT::Test::Permission->make_website;
    $plugin->set_config_value('openai_api_key', '', 'system');
    my $unindexed = MT::Test::Permission->make_entry(blog_id => $unindexed_site->id, title => 'Unindexed');
    $plugin->set_config_value('openai_api_key', 'openai-test', 'system');
    @embedded = ();
    request(blog_id => $unindexed_site->id);
    like $app->generic_error, qr/Generate the search index/, 'no index explains CLI';
    is scalar @embedded, 0, 'does not embed missing document or pointless query';
    is scalar @sent, 0, 'no Jev call';
    MT::Plugin::Jev::Embedding->refresh($unindexed);
    my $index = MT->model('jev_embedding')->load({object_type => 'entry', object_id => $unindexed->id});
    $index->source_hash('old'); $index->save;
    @embedded = ();
    request(blog_id => $unindexed_site->id);
    like $app->generic_error, qr/Generate the search index/, 'stale hash is omitted';
    is scalar @embedded, 0, 'search does not repair indexes';
};

subtest 'CMS search uses forked workers and retains its database connection and ranking' => sub {
    my $fork_site = MT::Test::Permission->make_website(name => 'Forked search');
    my @entries = map { MT::Test::Permission->make_entry(blog_id => $fork_site->id,
        title => "Fork result $_", text => 'Content') } 1..5;
    my %scores = map { ('entry_' . $entries[$_]->id) => $_ } 0..4;
    my $parent = $$;
    no warnings qw(redefine once);
    local *MT::Plugin::Jev::Client::evaluate_batches = $mock->original('evaluate_batches');
    for my $concurrency (1, 2, 5, 10) {
        $plugin->set_config_value('jev_concurrency', $concurrency, 'system');
        local *MT::Plugin::Jev::Client::_request = sub {
            my ($self, $body, $ids) = @_;
            die 'Concurrency setting not passed to client' unless $self->{concurrency} == $concurrency;
            die 'Wrong execution process' if ($$ == $parent) != ($concurrency == 1);
            return {map { $_ => {noul => 0.9, score => $scores{$_}} } @$ids};
        };
        request(blog_id => $fork_site->id, limit => 'all');
        ok !$app->generic_error, "CMS search succeeds with concurrency $concurrency" or diag $app->generic_error;
        like $app->content, qr/>Fork result 5<.*>Fork result 4<.*>Fork result 3<.*>Fork result 2<.*>Fork result 1</s,
            'all answers combined before sorting by Score';
    }
    $plugin->set_config_value('jev_concurrency', 5, 'system');
    is(MT->model('entry')->count({blog_id => $fork_site->id}), 5, 'parent can still query MT database');
    request(blog_id => $fork_site->id, is_jev => 0, search => 'Fork result 3');
    ok !$app->generic_error, 'ordinary CMS search still works afterwards';
    like $app->content, qr/>Fork result 3</, 'ordinary search result';
};

if ($ENV{JEV_TEST_HTML_DIR}) {
    if ($ENV{JEV_TEST_HTML_LANGUAGE}) {
        $admin->preferred_language($ENV{JEV_TEST_HTML_LANGUAGE});
        $admin->save or die $admin->errstr;
    }
    for my $mode ('search', 'normal') {
        request(is_jev => $mode eq 'search' ? 1 : 0, search => '導入');
        open my $fh, '>:encoding(UTF-8)', "$ENV{JEV_TEST_HTML_DIR}/$mode.html" or die $!;
        print {$fh} $app->content;
        close $fh;
    }
}

done_testing;
