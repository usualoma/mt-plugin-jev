use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use Test::MockModule;
use MT::Test::Permission;
use MT::Plugin::Jev::Content;
use MT::Plugin::Jev::Embedding;
use MT::Plugin::Jev::OpenAIClient;

my @sent;
my $mock = Test::MockModule->new('MT::Plugin::Jev::OpenAIClient');
$mock->redefine(embed => sub { push @sent, $_[1]; [0.6, 0.8, (0) x 3070] });
$MT::Plugin::Jev::Test::env->prepare_fixture('db');
is scalar @sent, 0, 'upgrade/initial fixtures never call OpenAI';
my $plugin = MT->component('Jev');
my $site = MT::Test::Permission->make_website;
my $entry = MT::Test::Permission->make_entry(blog_id => $site->id, title => '導入', text => '<p>困難 &amp; 解決</p>');
my $model = MT->model('jev_embedding');
is $model->count, 0, 'saving with no key leaves index empty';
$plugin->set_config_value('openai_api_key', 'fake-test', 'system');
$entry->save or die $entry->errstr;
is scalar @sent, 1, 'model save creates embedding';
my $index = $model->load({object_type => 'entry', object_id => $entry->id});
ok $index, 'index saved';
is length($index->vector), 12288, 'float32 BLOB';
my $vector = $index->unpack_vector;
cmp_ok abs($vector->[0] - 0.6), '<', 0.000001, 'float32 round-trip';
cmp_ok abs($model->similarity($vector, $vector) - 1), '<', 0.000001, 'cosine self-similarity';
my $document = MT::Plugin::Jev::Content->index_document($entry);
ok $index->current($document->{hash}), 'content hash and profile agree';
like $document->{text}, qr/困難 & 解決/, 'HTML normalized without truncation';
$entry->save or die $entry->errstr;
is scalar @sent, 1, 'unchanged save skips API';
$entry->status(1); $entry->save or die $entry->errstr;
is scalar @sent, 1, 'status change needs no embedding';
$entry->text('追加の本文'); $entry->save or die $entry->errstr;
is scalar @sent, 2, 'changed text regenerates';
ok !$index->current(MT::Plugin::Jev::Content->index_document($entry)->{hash}), 'old content not current';
is $model->count, 1, 'replaces index rather than duplicating';
is $model->refresh($entry), 'skipped', 'CLI-style refresh reuses current index';
is $model->refresh($entry, force => 1), 'generated', 'force rebuild';
is scalar @sent, 3, 'force actually calls';
my $page = MT::Test::Permission->make_page(blog_id => $site->id, title => 'page');
ok $model->load({object_type => 'page', object_id => $page->id}), 'page hook and distinct class';
my $ct = MT::Test::Permission->make_content_type(blog_id => $site->id);
my $record = MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $ct->id, label => '記録');
my $record_index = $model->load({object_type => 'content_data', object_id => $record->id});
is $record_index->content_type_id, $ct->id, 'content data hook and type';
my $last = scalar @sent;
$record->remove; $page->remove;
ok !$model->load({object_type => 'content_data', object_id => $record->id}), 'content data deletion removes index';
ok !$model->load({object_type => 'page', object_id => $page->id}), 'page deletion removes index';
is scalar @sent, $last, 'deletion makes no calls';

$index = $model->load({object_type => 'entry', object_id => $entry->id});
$index->model('old-model');
ok !$index->current(MT::Plugin::Jev::Content->index_document($entry)->{hash}), 'old model rejected';
$index->model('text-embedding-3-large'); $index->dimensions(10);
ok !$index->current(MT::Plugin::Jev::Content->index_document($entry)->{hash}), 'old dimension rejected';
$index->dimensions(3072); $index->text_version(0);
ok !$index->current(MT::Plugin::Jev::Content->index_document($entry)->{hash}), 'old normalization rejected';
$index->vector('bad');
my $error; eval { $index->unpack_vector; 1 } or $error = $@;
like "$error", qr/Invalid stored embedding/, 'bad BLOB refused';

subtest 'shortened embedding retains full source for freshness and evaluation' => sub {
    my $original = \&MT::Plugin::Jev::OpenAIClient::embed;
    my @inputs;
    $mock->redefine(embed => sub {
        my ($client, $text, %args) = @_;
        push @inputs, $args{shorten}->($text, 0.8);
        return [1, (0) x 3071];
    });
    my $full = '長い本文。' x 2000;
    my $long = MT::Test::Permission->make_entry(blog_id => $site->id,
        title => 'タイトルは残す', text => $full . '末尾に料金の言及がある');
    my $document = MT::Plugin::Jev::Content->index_document($long);
    my $saved = $model->load({object_type => 'entry', object_id => $long->id});
    ok $saved->current($document->{hash}), 'index uses full document hash';
    unlike $inputs[-1], qr/末尾に料金/, 'embedding copy can omit the tail';
    like $document->{text}, qr/末尾に料金/, 'full search fields retain the tail';
    is(MT->model('entry')->load($long->id)->text, $full . '末尾に料金の言及がある', 'stored article remains intact');
    $long->text($full . '末尾に費用の言及がある');
    $long->save or die $long->errstr;
    is scalar @inputs, 2, 'change only in omitted tail still refreshes embedding';
    $long->remove;
    $mock->redefine(embed => $original);
};

subtest 'numeric float32 path preserves the previous cosine values' => sub {
    my $query = $model->normalized([map { cos($_ / 3) } 1..3072]);
    for my $source (
        [0.6, 0.8, (0) x 3070],
        [1, (0) x 3071],
        [map { sin($_ / 7) } 1..3072],
        [map { sin($_ / 11) } 1..3072],
    ) {
        my $stored = $model->normalized($source);
        my $object = $model->new;
        $object->vector(pack('f<*', @$stored));
        my $previous = $model->normalized([unpack('f<*', $object->vector)]);
        my $current = $object->unpack_vector;
        is_deeply $current, $previous, 'identical normalized components after float32 rounding';
        is $model->similarity($query, $current), $model->similarity($query, $previous),
            'identical cosine score, including tie behavior';
    }
};

subtest 'corrupt numeric BLOBs still fail instead of entering ranking' => sub {
    # IEEE754 little-endian representations avoid generating NaN/Inf through
    # string conversion or platform-specific floating-point exceptions.
    for my $first (
        pack('L<', 0x7fc00000), pack('L<', 0x7f800000), pack('L<', 0xff800000),
        pack('f<', 1.01), pack('f<', -1.01), pack('f<', 0),
    ) {
        my $object = $model->new;
        $object->vector($first . pack('f<*', (0) x 3071));
        my $error;
        eval { $object->unpack_vector; 1 } or $error = $@;
        isa_ok $error, 'MT::Plugin::Jev::Error';
        like "$error", qr/Invalid stored embedding/, 'NaN, infinity, out-of-range or zero vector rejected';
    }
};

# A failed regeneration leaves no stale vector, without a recovery subsystem.
$mock->redefine(embed => sub { MT::Plugin::Jev::fail('OpenAI returned HTTP [_1].', 400) });
$entry->text('new content that cannot be embedded');
$error = undef;
eval { $model->refresh($entry); 1 } or $error = $@;
isa_ok $error, 'MT::Plugin::Jev::Error';
ok !$model->load({object_type => 'entry', object_id => $entry->id}), 'failed update removed old index';
my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    ok $entry->save, 'API failure in save hook does not undo the saved article';
}
is(MT->model('entry')->load($entry->id)->text, 'new content that cannot be embedded', 'article survives failed indexing');
ok !$model->load({object_type => 'entry', object_id => $entry->id}), 'failed save hook leaves index missing';
$entry->remove;
is $model->count, 0, 'no orphan indexes remain';
done_testing;
