use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../t/lib";
use Test::More;
BEGIN { plan skip_all => 'Set JEV_PROFILE=1 to profile search with a temporary database and mocked APIs.' unless $ENV{JEV_PROFILE} }
use MT::Plugin::Jev::Test;
use MT::Test::Permission;
use MT::Test::App;
use Test::MockModule;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP;
use MT::Plugin::Jev::Search;

sub now { clock_gettime(CLOCK_MONOTONIC) }
my ($enabled, %metrics, @stack);
sub measured {
    my ($name, $code, @args) = @_;
    return $code->(@args) unless $enabled;
    my $frame = {name => $name, children => 0};
    push @stack, $frame;
    my $start = now();
    my $want = wantarray;
    my @result;
    if (!defined $want) { $code->(@args) }
    elsif ($want) { @result = $code->(@args) }
    else { $result[0] = $code->(@args) }
    my $elapsed = now() - $start;
    pop @stack;
    $stack[-1]{children} += $elapsed if @stack;
    $metrics{$name}{calls}++;
    $metrics{$name}{inclusive_seconds} += $elapsed;
    $metrics{$name}{exclusive_seconds} += $elapsed - $frame->{children};
    return $want ? @result : $result[0];
}

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $openai = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
my @vector = map { sin($_ + 1) / sqrt(3072) } 0..3071;
$openai->redefine(embed => sub { measured('query_embedding_mock', sub { [@vector] }) });
my $jev = Test::MockModule->new('MT::Plugin::Jev::Client');
$jev->redefine(_request => sub {
    my ($self, $body, $ids) = @_;
    return {map { $_ => {noul => 0.9, score => 3} } @$ids};
});
my $plugin = MT->component('Jev');
$plugin->set_config_value({openai_api_key => 'profile-fake', jev_api_key => 'profile-fake',
    jev_model => 'jev-latest', jev_threshold => 0.5, jev_candidate_limit => 50, jev_batch_size => 5}, 'system');

my $count = $ENV{JEV_PROFILE_COUNT} || 1000;
die 'Invalid count' unless $count =~ /\A[1-9][0-9]*\z/ && $count <= 10000;
open my $input, '<:encoding(UTF-8)', "$FindBin::Bin/../../../specs/demo-data/jev-demo-1000.txt" or die $!;
my $text = do { local $/; <$input> };
my @documents = map {
    my ($title) = /^TITLE: (.+)$/m;
    my ($body) = /\nBODY:\n(.*?)\n-----\n/s;
    defined($title) && defined($body) ? {title => $title, body => $body} : ()
} split /\n--------\n/, $text;
is scalar @documents, 1000, 'demo dataset loaded';
my $site = MT::Test::Permission->make_website(name => 'Isolated search profile');
my $start = now();
for my $i (0 .. $count - 1) {
    my $doc = $documents[$i % @documents];
    MT::Test::Permission->make_entry(blog_id => $site->id, title => $doc->{title}, text => $doc->{body}, status => 1);
}
diag sprintf 'Prepared %d demo documents and mock embeddings in %.3fs', $count, now() - $start;

my @mocks;
sub instrument {
    my ($package, $method, $name) = @_;
    my $original = $package->can($method) or die "$package\::$method missing";
    my $mock = Test::MockModule->new($package);
    $mock->mock($method => sub { measured($name, $original, @_) });
    push @mocks, $mock;
}
instrument('MT::Plugin::Jev::Search', '_matching_iter', 'candidate_selection_total');
instrument('MT::Plugin::Jev::Embedding', 'load', 'embedding_db_load');
instrument('MT::Plugin::Jev::Content', 'index_document', 'document_preparation');
instrument('MT::Plugin::Jev::Embedding', 'unpack_vector', 'vector_decode');
instrument('MT::Plugin::Jev::Embedding', 'normalized', 'vector_validation_normalization');
instrument('MT::Plugin::Jev::Embedding', 'similarity', 'vector_dot_product');
instrument('MT::Plugin::Jev::Client', 'evaluate_batches', 'jev_local_preparation_and_fork');
my $content = Test::MockModule->new('MT::Plugin::Jev::Content');
my $fields = MT::Plugin::Jev::Content->can('fields');
$content->redefine(fields => sub {
    return $fields->(@_) if @stack && $stack[-1]{name} eq 'document_preparation';
    return measured('candidate_fields', $fields, @_);
});
my $core = Test::MockModule->new('MT::CMS::Search');
my $incremental = MT::CMS::Search->can('incremental_iter');
$core->redefine(incremental_iter => sub {
    my $iter = $incremental->(@_);
    return sub { measured('entry_db_iteration', $iter, @_) };
});

my $app = MT::Test::App->new('MT::App::CMS');
$app->login(MT->model('author')->load(1));
$app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id});
my $params = {__mode => 'search_replace', _type => 'entry', blog_id => $site->id,
    search => '国産クラウドへのサイト移行で実際に困ったことがあり、料金や費用には一切言及していない記事',
    do_search => 1, is_jev => 1, limit => 'all'};

my (@runs, $expected_ids);
sub search_run {
    my ($run, $variant) = @_;
    %metrics = (); @stack = ();
    $enabled = $run ? 1 : 0;
    $start = now();
    $app->get($params);
    my $seconds = now() - $start;
    $enabled = 0;
    ok !$app->generic_error, "search run $run succeeds" or diag $app->generic_error;
    my @shown = $app->content =~ /\[(JEV-\d{4})\]/g;
    if ($expected_ids) {
        is_deeply \@shown, $expected_ids, 'same displayed demo articles in the same order';
    } else {
        ok @shown >= 50, 'all fifty demo results found in rendered HTML';
        $expected_ids = \@shown;
    }
    my $record = {run => $run, instrumented => $run ? JSON::PP::true : JSON::PP::false,
        variant => $variant, total_seconds => $seconds, metrics => {%metrics}};
    push @runs, $record;
    diag(JSON::PP->new->canonical->encode($record));
}
search_run($_, 'current') for 0..3;

# Counterfactual only inside this isolated process, using valid vectors that
# this fixture has just normalized and saved. Production code is not changed.
if ($ENV{JEV_PROFILE_ABLATION}) {
    my $skip = Test::MockModule->new('MT::Plugin::Jev::Embedding');
    $skip->redefine(unpack_vector => sub {
        measured('vector_decode', sub {
            my ($index) = @_;
            die 'Unexpected vector length' unless length($index->vector) == 4 * 3072;
            return [unpack('f<*', $index->vector)];
        }, @_);
    });
    search_run($_, 'skip_stored_vector_validation_normalization') for 4..6;
}
if (my $path = $ENV{JEV_PROFILE_OUTPUT}) {
    open my $output, '>', $path or die $!;
    print {$output} JSON::PP->new->canonical->pretty->encode({
        documents => 0 + $count, dimensions => 3072, candidate_limit => 50, batch_size => 5,
        concurrency => 2, apis_mocked => JSON::PP::true,
        backend => $ENV{MT_TEST_BACKEND} || 'SQLite', runs => \@runs,
    });
    close $output or die $!;
}
done_testing;
