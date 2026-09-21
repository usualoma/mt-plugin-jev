#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
BEGIN {
    my $mt = $ENV{MT_HOME} or die "Set MT_HOME to the MT checkout.\n";
    unshift @INC, "$mt/lib", "$mt/extlib";
    chdir $mt or die $!;
}
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use JSON::PP;
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use Test::MockModule;
use CGI;
use MT::App::CMS;

my ($site, $author, $live, $output, $query_file);
GetOptions('blog-id=i' => \$site, 'author-id=i' => \$author, 'live' => \$live,
    'output=s' => \$output, 'query-file=s' => \$query_file) or die "Invalid options\n";
die "Use --blog-id ID --author-id ID [--live] [--query-file UTF8_FILE] [--output JSON_FILE]\n"
    unless $site && $author && !@ARGV;
my $query = '国産クラウドへのサイト移行で実際に困ったことがあり、料金や費用には一切言及していない記事';
if ($query_file) {
    open my $fh, '<:encoding(UTF-8)', $query_file or die $!;
    $query = do { local $/; <$fh> };
    $query =~ s/\s+\z//;
}
local $ENV{HTTP_HOST} = 'localhost';
local $ENV{SCRIPT_NAME} = '/cgi-bin/mt/mt.cgi';
local $ENV{REQUEST_METHOD} = 'GET';
my $cgi = CGI->new({__mode => 'search_replace', _type => 'entry', blog_id => $site,
    search => $query, do_search => 1, is_jev => 1, limit => 'all'});
my $app = MT::App::CMS->new(CGIObject => $cgi) or die MT->errstr;
MT->set_instance($app);
$app->init_request(CGIObject => $cgi);
my $user = MT->model('author')->load($author) or die "Author not found\n";
$app->user($user);
$app->blog(MT->model('blog')->load($site) or die "Site not found\n");
$app->permissions($user->permissions($site));
require MT::Plugin::Jev::Search;
require MT::CMS::Search;

# This invokes only the search handler, not login/session creation. Reject
# model writes so the existing database remains unchanged during profiling.
my $readonly = Test::MockModule->new('MT::Object');
$readonly->redefine(save => sub {
    die 'Unexpected model save for ' . ref($_[0]) . "\n" . join("\n", map {
        my (undef, $file, $line, $sub) = caller($_);
        defined $file ? "$sub at $file:$line" : ()
    } 0..6) . "\n";
});
$readonly->redefine(remove => sub { die "Unexpected model remove during read-only profiling\n" });
my $cms = Test::MockModule->new('MT::App::CMS');
$cms->redefine(add_to_favorite_blogs => sub { });
$cms->redefine(add_to_favorite_websites => sub { });
my ($enabled, %metrics, @stack, @mocks, $openai_usage, $jev_tokens);
sub now { clock_gettime(CLOCK_MONOTONIC) }
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
    my $seconds = now() - $start;
    pop @stack;
    $stack[-1]{children} += $seconds if @stack;
    $metrics{$name}{calls}++;
    $metrics{$name}{inclusive_seconds} += $seconds;
    $metrics{$name}{exclusive_seconds} += $seconds - $frame->{children};
    return $want ? @result : $result[0];
}
sub instrument {
    my ($package, $method, $name) = @_;
    my $original = $package->can($method) or die "Missing $package\::$method";
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
my $content = Test::MockModule->new('MT::Plugin::Jev::Content');
my $fields = MT::Plugin::Jev::Content->can('fields');
$content->redefine(fields => sub {
    return $fields->(@_) if @stack && $stack[-1]{name} eq 'document_preparation';
    measured('candidate_fields', $fields, @_);
});
my $core = Test::MockModule->new('MT::CMS::Search');
my $incremental = MT::CMS::Search->can('incremental_iter');
$core->redefine(incremental_iter => sub {
    my $iter = $incremental->(@_);
    return sub { measured('entry_db_iteration', $iter, @_) };
});
my $openai = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
my $embed = MT::Plugin::Jev::OpenAIClient->can('embed');
$openai->redefine(embed => sub {
    my $self = $_[0];
    my $result = measured('openai', $live ? $embed : sub { [1, (0) x 3071] }, @_);
    $openai_usage = $self->usage if $live;
    return $result;
});
my $dir = tempdir(CLEANUP => 1);
my $jev = Test::MockModule->new('MT::Plugin::Jev::Client');
my $request = MT::Plugin::Jev::Client->can('_request');
my $evaluate = MT::Plugin::Jev::Client->can('evaluate_batches');
$jev->redefine(_request => sub {
    my ($self, $body, $ids, $deadline) = @_;
    my $start = now();
    my $result = $live ? $request->(@_) : {map { $_ => {noul => 0.9, score => 3} } @$ids};
    my $event = {start => $start, seconds => now() - $start, documents => scalar @$ids, pid => $$};
    open my $fh, '>>', "$dir/requests.jsonl" or die $!;
    flock $fh, LOCK_EX or die $!;
    print {$fh} JSON::PP->new->encode($event), "\n";
    close $fh or die $!;
    return $result;
});
$jev->redefine(evaluate_batches => sub {
    my $self = $_[0];
    my $result = measured($self->provider eq 'OpenAI' ? 'openai_evaluation' : 'jev', $evaluate, @_);
    $jev_tokens = $self->input_tokens;
    return $result;
});

my $config = MT::Plugin::Jev::config();
$enabled = 1;
my $start = now();
my $template = MT::CMS::Search::search_replace($app) or die $app->errstr;
die "Search failed: " . $template->param('error') if $template->param('error');
my $render_start = now();
my $html = $app->build_page($template) or die $app->errstr;
my $seconds = now() - $start;
my $render_seconds = now() - $render_start;
$enabled = 0;
my @requests;
if (open my $fh, '<', "$dir/requests.jsonl") {
    @requests = map { JSON::PP->new->decode($_) } <$fh>;
    $_->{start} -= $start for @requests;
}
my $result = {site_id => $site, apis_live => $live ? JSON::PP::true : JSON::PP::false,
    backend => $app->config('ObjectDriver'), query => $query,
    total_seconds => $seconds, rendering_seconds => $render_seconds,
    candidate_limit => 0 + $config->{jev_candidate_limit}, batch_size => 0 + $config->{jev_batch_size},
    evaluation_provider => $config->{jev_evaluator}, concurrency => 0 + $config->{jev_concurrency},
    evaluation_model => $config->{$config->{jev_evaluator} eq 'openai' ? 'openai_evaluation_model' : 'jev_model'},
    evaluation_input_tokens => $jev_tokens,
    jev_model => $config->{jev_model}, metrics => \%metrics, requests => \@requests,
    openai_usage => $openai_usage, jev_input_tokens => $jev_tokens};
my $json = JSON::PP->new->utf8->canonical->pretty->encode($result);
if ($output) {
    open my $fh, '>', $output or die $!;
    print {$fh} $json;
    close $fh or die $!;
}
print $json;
