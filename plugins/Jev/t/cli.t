use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use MT::Test::Permission;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use IPC::Run3;
use Encode qw(decode);
use MT::Plugin::Jev::Embedding;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $site = MT::Test::Permission->make_website;
my $elsewhere = MT::Test::Permission->make_website;
my $entry = MT::Test::Permission->make_entry(blog_id => $site->id, title => 'CLI entry');
my $page = MT::Test::Permission->make_page(blog_id => $site->id, title => 'CLI page');
my $ct = MT::Test::Permission->make_content_type(blog_id => $site->id);
my $category = MT::Test::Permission->make_category(blog_id => $site->id, label => '分類');
my $tag = MT::Test::Permission->make_tag(name => 'タグ');
my (@fields, %data);
for my $type (qw(categories tags)) {
    my $field = MT::Test::Permission->make_content_field(
        blog_id => $site->id, content_type_id => $ct->id, type => $type, name => $type);
    push @fields, {id => $field->id, unique_id => $field->unique_id, name => $type,
        type => $type, order => scalar @fields, options => {label => $type}};
    $data{$field->id} = [$type eq 'categories' ? $category->id : $tag->id];
}
$ct->fields(\@fields);
$ct->save or die $ct->errstr;
my $record = MT::Test::Permission->make_content_data(blog_id => $site->id,
    content_type_id => $ct->id, label => 'CLI data', data => \%data);
MT::Test::Permission->make_entry(blog_id => $elsewhere->id, title => 'Outside scope');
my $plugin = MT->component('Jev');
$plugin->set_config_value('openai_api_key', 'fake-cli-key', 'system');
my $dir = tempdir(CLEANUP => 1);
open my $fh, '>', "$dir/JevFakeOpenAI.pm" or die $!;
print {$fh} <<'MOCK';
package JevFakeOpenAI;
use MT::Plugin::Jev::OpenAIClient;
no warnings 'redefine';
*MT::Plugin::Jev::OpenAIClient::embed = sub {
    die 'deliberate failure' if $ENV{JEV_FAIL};
    if ($ENV{JEV_JA_ERROR}) {
        MT->instance->set_language('ja');
        MT::Plugin::Jev::fail('OpenAI embedding input exceeds the maximum of [_1] tokens.', 8192)
            if $ENV{JEV_JA_ERROR} eq 'limit_only';
        MT::Plugin::Jev::fail('OpenAI embedding input has [_1] tokens; the maximum is [_2].', 9000, 8192);
    }
    [1, (0) x 3071];
};
1;
MOCK
close $fh;
local $ENV{PERL5LIB} = join ':', $dir, "$ENV{MT_HOME}/lib", "$ENV{MT_HOME}/extlib", "$FindBin::Bin/../lib";
sub cli {
    my (@args) = @_;
    my ($out, $err);
    run3 [$^X, '-MJevFakeOpenAI', "$FindBin::Bin/../../../tools/Jev/build-index", @args], undef, \$out, \$err;
    return ($? >> 8, $out, $err);
}
my ($status, $out, $err) = cli('--blog-id', $site->id, '--type', 'entry');
is $status, 0, 'CLI initializes MT and builds index' or diag $err;
like $out, qr/entry @{[$entry->id]}: generated/, 'entry generated';
unlike $out, qr/page|content_data/, 'type filter';
is(MT->model('jev_embedding')->count, 1, 'only selected site/type indexed');
($status, $out, $err) = cli('--blog-id', $site->id);
is $status, 0, 'all three types supported' or diag $err;
like $out, qr/entry @{[$entry->id]}: skipped/, 'same hash skipped across processes';
like $out, qr/page @{[$page->id]}: generated/, 'page generated once';
like $out, qr/content_data @{[$record->id]}: generated/, 'content with categories and tags generated without a CMS user';
is(MT->model('jev_embedding')->count, 3, 'other site excluded');
($status, $out, $err) = cli('--blog-id', $site->id, '--force');
is $status, 0, 'force rebuild succeeds' or diag $err;
is scalar(() = $out =~ /generated/g), 3, 'force refreshes all three';
{
    local $ENV{JEV_FAIL} = 1;
    ($status, $out, $err) = cli('--blog-id', $site->id, '--force');
}
is $status, 1, 'failed generation stops CLI';
like $err, qr/entry @{[$entry->id]}: Index generation failed/, 'failure names the document';
unlike $err, qr/fake-cli-key|deliberate failure/, 'private exception not printed';
($status, $out, $err) = cli('--blog-id', $site->id);
is $status, 0, 'rerunning needs no resume token' or diag $err;
is scalar(() = $out =~ /generated/g), 1, 'only missing record regenerated';
{
    local $ENV{JEV_JA_ERROR} = 1;
    ($status, $out, $err) = cli('--blog-id', $site->id, '--type', 'entry', '--force');
}
is $status, 1, 'translated API error stops CLI';
unlike $err, qr/Wide character/, 'Japanese error produces no encoding warning';
like decode('UTF-8', $err), qr/9000トークン.*8192トークン/, 'Japanese token error is valid UTF-8';
{
    local $ENV{JEV_JA_ERROR} = 'limit_only';
    ($status, $out, $err) = cli('--blog-id', $site->id, '--type', 'entry', '--force');
}
is $status, 1, 'context limit without input count stops CLI after retries';
unlike $err, qr/Wide character/, 'limit-only Japanese error produces no encoding warning';
like decode('UTF-8', $err), qr/上限の8192トークンを超えています/, 'known context limit translated without input count';
($status, $out, $err) = cli('--type', 'asset');
ok $status, 'unsupported type rejected';
($status, $out, $err) = cli('--help');
is $status, 0, 'help is usable';
like $out, qr/--force/, 'options documented';
like $out, qr{perl tools/Jev/build-index}, 'help shows the new command path';

# The extra directory level must work in an installed MT tree without relying
# on the MT_HOME/PERL5LIB that the test harness normally supplies.
my $installed = tempdir(CLEANUP => 1);
make_path("$installed/tools/Jev");
symlink "$ENV{MT_HOME}/lib", "$installed/lib" or die $!;
symlink "$ENV{MT_HOME}/extlib", "$installed/extlib" or die $!;
copy "$FindBin::Bin/../../../tools/Jev/build-index", "$installed/tools/Jev/build-index" or die $!;
{
    local %ENV = %ENV;
    delete @ENV{qw(MT_HOME PERL5LIB SCRIPT_FILENAME)};
    run3 [$^X, "$installed/tools/Jev/build-index", '--help'], undef, \$out, \$err;
    is $? >> 8, 0, 'nested command locates MT without environment overrides' or diag $err;
    like $out, qr{perl tools/Jev/build-index}, 'installed command starts successfully';
}
done_testing;
