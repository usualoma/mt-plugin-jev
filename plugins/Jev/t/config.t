use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use MT::Plugin::Jev::Test;
use Test::More;
use MT::Test::App;
use MT::Plugin::Jev::Callbacks;

$MT::Plugin::Jev::Test::env->prepare_fixture('db');
my $plugin = MT->component('Jev');
my $key = 'test-secret-value-1234';
my %settings = (openai_api_key => 'openai-secret-9876', jev_candidate_limit => 50, jev_api_key => $key, jev_model => 'jev-latest', jev_threshold => 0.5, jev_batch_size => 5);
$plugin->set_config_value(\%settings, 'system');
my $app = MT::Test::App->new('MT::App::CMS');
$app->login(MT->model('author')->load(1));
$app->get_ok({__mode => 'cfg_plugins'});
ok !$app->generic_error, 'plugin settings render' or diag $app->generic_error;
unlike $app->content, qr/\Q$key\E/, 'stored key is absent from HTML';
like $app->content, qr/\*{8}1234/, 'only suffix displayed';
unlike $app->content, qr/openai-secret-9876/, 'OpenAI key absent from HTML';
like $app->content, qr/\*{8}9876/, 'OpenAI suffix displayed';
ok $app->wq_find('#openai_api_key')->attr('disabled'), 'OpenAI key unchanged';
is $app->wq_find('#jev_candidate_limit')->attr('value'), 50, 'candidate default';
is $app->wq_find('#jev_concurrency')->attr('value'), 5, 'existing configuration receives concurrency default';
is $app->wq_find('#jev_log_usage option[selected]')->attr('value'), 0, 'token usage logging defaults to OFF';
is $app->wq_find('#jev_evaluator option[selected]')->attr('value'), 'jev', 'existing configuration keeps Jev';
is $app->wq_find('#openai_evaluation_model')->attr('value'), 'gpt-5.4-mini', 'OpenAI evaluation default model';
ok $app->wq_find('#jev_api_key')->attr('disabled'), 'unchanged key is not submitted';
is $app->wq_find('#jev_api_key')->attr('type'), 'password', 'key editor is a password input';
like $app->content, qr{/mt-static/plugins/Jev/system_config\.js}, 'settings script has a usable URL';
is $app->wq_find('#jev_header_default option[selected]')->attr('value'), 1, 'header search defaults to ON';
is $app->wq_find('script[data-jev-header]')->size, 1, 'header script included once';
is $app->wq_find('script[data-jev-header]')->attr('data-default'), 1, 'header receives ON default';

sub settings_form_id {
    my $id;
    $app->wq_find('form')->each(sub {
        $id = $_->attr('id') if $_->find('#jev_api_key')->size;
    });
    return $id;
}
my $form_id = settings_form_id();
ok $form_id, 'settings use the standard plugin form';
$app->post_form_ok($form_id, {jev_threshold => '0.7', jev_header_default => '0', jev_concurrency => '10', jev_log_usage => '1'});
ok !$app->generic_error, 'save without key succeeds' or diag $app->generic_error;
MT->request('plugin_config.Jev', undef);
is $plugin->get_config_value('jev_api_key', 'system'), $key, 'unchanged API key preserved';
is $plugin->get_config_value('openai_api_key', 'system'), 'openai-secret-9876', 'OpenAI key preserved';
is $plugin->get_config_value('jev_threshold', 'system'), 0.7, 'threshold saved';
is $plugin->get_config_value('jev_header_default', 'system'), 0, 'OFF saved';
is MT::Plugin::Jev::config()->{jev_concurrency}, 10, 'saved concurrency reaches search configuration';
is MT::Plugin::Jev::config()->{jev_log_usage}, 1, 'token usage logging can be enabled';

$app->get_ok({__mode => 'cfg_plugins'});
is $app->wq_find('#jev_concurrency')->attr('value'), 10, 'concurrency persists after reload';
is $app->wq_find('#jev_log_usage option[selected]')->attr('value'), 1, 'usage logging persists after reload';
is $app->wq_find('#jev_header_default option[selected]')->attr('value'), 0, 'OFF remains selected after reload';
is $app->wq_find('script[data-jev-header]')->attr('data-default'), 0, 'header receives OFF default';
$form_id = settings_form_id();
my $form = $app->form($form_id);
$form->find_input('jev_api_key')->disabled(0);
$form->param('jev_api_key', 'replacement-secret-5678');
$form->find_input('openai_api_key')->disabled(0);
$form->param('openai_api_key', 'new-openai-secret-4321');
$app->post_ok($form->click);
ok !$app->generic_error, 'key update succeeds';
MT->request('plugin_config.Jev', undef);
is $plugin->get_config_value('jev_api_key', 'system'), 'replacement-secret-5678', 'new key stored';
is $plugin->get_config_value('openai_api_key', 'system'), 'new-openai-secret-4321', 'new OpenAI key stored';
is $plugin->get_config_value('jev_header_default', 'system'), 0, 'key update preserves OFF';

$app->get_ok({__mode => 'cfg_plugins'});
$app->post_form_ok(settings_form_id(), {jev_header_default => '1', jev_concurrency => '1', jev_log_usage => '0'});
MT->request('plugin_config.Jev', undef);
is $plugin->get_config_value('jev_header_default', 'system'), 1, 'ON can be restored';
is MT::Plugin::Jev::config()->{jev_concurrency}, 1, 'sequential mode can be saved';
is MT::Plugin::Jev::config()->{jev_log_usage}, 0, 'token usage logging can be disabled again';

$app->get_ok({__mode => 'cfg_plugins'});
$form = $app->form(settings_form_id());
$form->find_input('openai_api_key')->disabled(0);
$form->param('openai_api_key', '');
$app->post_ok($form->click);
MT->request('plugin_config.Jev', undef);
is $plugin->get_config_value('openai_api_key', 'system'), '', 'explicit empty edit removes OpenAI key';
is $plugin->get_config_value('jev_api_key', 'system'), 'replacement-secret-5678', 'removing OpenAI key preserves TypeSafe key';

subtest 'invalid settings rejected before saving' => sub {
    for my $invalid (
        {jev_threshold => -0.1}, {jev_threshold => 1.1}, {jev_threshold => 'NaN'},
        {jev_batch_size => 0}, {jev_batch_size => 51}, {jev_batch_size => '1.5'},
        {jev_model => ''}, {jev_model => "jev\nmodel"}, {jev_api_key => "key\nHeader: value"},
        {openai_api_key => "key\nInjected: header"}, {jev_candidate_limit => 0}, {jev_candidate_limit => 501}, {jev_candidate_limit => '1.1'},
        {jev_header_default => '2'}, {jev_header_default => 'true'},
        {jev_log_usage => '2'}, {jev_log_usage => 'true'}, {jev_log_usage => ''},
        {jev_evaluator => 'other'}, {jev_evaluator => ''}, {jev_evaluator => undef},
        {openai_evaluation_model => ''}, {openai_evaluation_model => "bad\nmodel"},
        map { +{jev_concurrency => $_} } (undef, '', 0, -1, 11, '1.5', 'NaN', 'Inf'),
    ) {
        my %data = (%settings, jev_concurrency => 5, jev_evaluator => 'jev', openai_evaluation_model => 'gpt-5.4-mini', %$invalid);
        ok !MT::Plugin::Jev::Callbacks::save_config_filter(undef, $plugin, \%data, 'system'), 'invalid value rejected';
        ok $plugin->errstr, 'validation error available';
    }
};

subtest 'invalid concurrency is not persisted through the settings form' => sub {
    $app->get_ok({__mode => 'cfg_plugins'});
    $app->post_form_ok(settings_form_id(), {jev_concurrency => '11'});
    like $app->content, qr/The evaluation concurrency must be an integer from 1 to 10/, 'validation error rendered';
    MT->request('plugin_config.Jev', undef);
    is $plugin->get_config_value('jev_concurrency', 'system'), 1, 'previous valid value preserved';
};

subtest 'evaluation provider and model persist without changing keys' => sub {
    $app->get_ok({__mode => 'cfg_plugins'});
    $app->post_form_ok(settings_form_id(), {jev_evaluator => 'openai', openai_evaluation_model => 'gpt-4.1-mini'});
    ok !$app->generic_error, 'OpenAI selection saved';
    MT->request('plugin_config.Jev', undef);
    is MT::Plugin::Jev::config()->{jev_evaluator}, 'openai', 'provider saved';
    is MT::Plugin::Jev::config()->{openai_evaluation_model}, 'gpt-4.1-mini', 'custom model saved';
    is $plugin->get_config_value('jev_api_key', 'system'), 'replacement-secret-5678', 'TypeSafe key retained';
    $app->get_ok({__mode => 'cfg_plugins'});
    is $app->wq_find('#jev_evaluator option[selected]')->attr('value'), 'openai', 'OpenAI remains selected';
    is $app->wq_find('#openai_evaluation_model')->attr('value'), 'gpt-4.1-mini', 'custom model rendered';
    $app->post_form_ok(settings_form_id(), {jev_evaluator => 'jev'});
    MT->request('plugin_config.Jev', undef);
    is MT::Plugin::Jev::config()->{jev_evaluator}, 'jev', 'can switch back to Jev';
};

if ($ENV{JEV_TEST_HTML_DIR}) {
    if ($ENV{JEV_TEST_HTML_LANGUAGE}) {
        my $author = MT->model('author')->load(1);
        $author->preferred_language($ENV{JEV_TEST_HTML_LANGUAGE});
        $author->save or die $author->errstr;
        $app->login($author);
    }
    $app->get_ok({__mode => 'cfg_plugins'});
    open my $fh, '>:encoding(UTF-8)', "$ENV{JEV_TEST_HTML_DIR}/settings.html" or die $!;
    print {$fh} $app->content;
    close $fh;
}

done_testing;
