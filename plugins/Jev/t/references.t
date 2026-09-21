use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use MT::Test::Permission;
use MT::Test::App;
use MT::Plugin::Jev::Content;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $admin = MT->model('author')->load(1);
my $site = MT::Test::Permission->make_website;
my $foreign_site = MT::Test::Permission->make_website;
my $ct = MT::Test::Permission->make_content_type(blog_id => $site->id);
my $related = MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $ct->id, label => 'Related record');
my $asset = MT::Test::Permission->make_asset(blog_id => $site->id, label => 'Media label');
my $foreign_asset = MT::Test::Permission->make_asset(blog_id => $foreign_site->id, label => 'Foreign secret');
my $category = MT::Test::Permission->make_category(blog_id => $site->id, label => '分類');
my $tag = MT::Test::Permission->make_tag(name => 'タグ');
my (@defs, %data, %id_by_type);
for my $type (qw(asset asset_image asset_audio asset_video categories tags content_type)) {
    my $field = MT::Test::Permission->make_content_field(
        blog_id => $site->id, content_type_id => $ct->id, type => $type, name => $type,
    );
    $id_by_type{$type} = $field->id;
    push @defs, { id => $field->id, unique_id => $field->unique_id, name => $type,
        type => $type, order => scalar @defs, options => {label => $type, source => $ct->id} };
    $data{$field->id} = $type eq 'categories' ? [$category->id]
        : $type eq 'tags' ? [$tag->id]
        : $type eq 'content_type' ? [$related->id]
        : [$asset->id, $foreign_asset->id, 999999];
}
$ct->fields(\@defs);
$ct->save or die $ct->errstr;
my $record = MT::Test::Permission->make_content_data(blog_id => $site->id, content_type_id => $ct->id, data => \%data);
my $app = MT::Test::App->new('MT::App::CMS');
$app->login($admin);
$app->get_ok({__mode => 'search_replace', _type => 'entry', blog_id => $site->id});
my $cms = $app->{_app};
$cms->user($admin);
MT->set_instance($cms);
my $api = $cms->registry('search_apis')->{content_data};
my $columns = [map { '__field:' . $_->{id} } @defs];
my $values = sub {
    my $fields = MT::Plugin::Jev::Content->fields($cms, $record, $columns, $api);
    return { map { $_->{name} => $_->{value} } @$fields };
};
my $sent = $values->();
for my $type (qw(asset asset_image asset_audio asset_video)) {
    is_deeply $sent->{'__field:' . $id_by_type{$type}}, [{id => $asset->id, label => 'Media label'}],
        "$type resolves labels and excludes foreign or missing assets";
}
is_deeply $sent->{'__field:' . $id_by_type{categories}}, [{id => $category->id, label => '分類'}], 'category label resolved';
is_deeply $sent->{'__field:' . $id_by_type{tags}}, [{id => $tag->id, label => 'タグ'}], 'tag name resolved';
is_deeply $sent->{'__field:' . $id_by_type{content_type}}, [{id => $related->id, label => 'Related record'}], 'related content label resolved';

my $writer = MT::Test::Permission->make_author;
my $role = MT::Test::Permission->make_role(name => 'Jev reference test writer', permissions => "'create_post'");
require MT::Association;
MT::Association->link($writer => $role => $site);
$cms->user($writer);
$sent = $values->();
for my $type (qw(asset asset_image asset_audio asset_video content_type)) {
    is_deeply $sent->{'__field:' . $id_by_type{$type}}, [], "$type does not disclose a reference without permission";
}
my $document = MT::Plugin::Jev::Content->index_document($record, $api);
unlike $document->{text}, qr/Media label|Foreign secret|Related record/, 'shared embedding excludes permission-dependent labels';
like $document->{text}, qr/分類/, 'shared category label included';
$cms->user($admin);
is(MT::Plugin::Jev::Content->index_document($record, $api)->{hash}, $document->{hash}, 'index text independent of current user');
$cms->set_language('ja');
is(MT::Plugin::Jev::Content->index_document($record, $api)->{hash}, $document->{hash}, 'index text independent of UI language');
done_testing;
