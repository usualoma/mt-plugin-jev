package MT::Plugin::Jev::Callbacks;

use strict;
use warnings;
use Scalar::Util qw(blessed);
use MT::Plugin::Jev;
use MT::Plugin::Jev::CMS;

sub system_config_template {
    my ($plugin, $param, $scope) = @_;
    return if $scope && $scope ne 'system';
    for my $provider (qw(jev openai)) {
        my $name = $provider . '_api_key';
        my $key = delete $param->{$name} // '';
        # MT load_config also creates flags whose names contain setting values.
        delete $param->{$_} for grep { /^\Q$name\E_/ } keys %$param;
        $param->{$provider . '_has_api_key'} = length($key) ? 1 : 0;
        $param->{$provider . '_masked_api_key'} = length($key) > 4 ? '********' . substr($key, -4) : '********';
    }
    return $plugin->load_tmpl('system_config.tmpl');
}

sub save_config_filter {
    my ($cb, $plugin, $data, $scope) = @_;
    return 1 unless $scope eq 'system';
    for my $name (qw(jev_api_key openai_api_key)) {
        $data->{$name} = $plugin->get_config_value($name, 'system') unless defined $data->{$name};
    }
    my $error;
    {
        local $@;
        eval { MT::Plugin::Jev::validate_config($data); 1 } or $error = $@;
    }
    if ($error) {
        die $error unless blessed($error) && $error->isa('MT::Plugin::Jev::Error');
        return $plugin->error($error->message);
    }
    return 1;
}

sub template_param_header {
    my ($cb, $app, $param, $tmpl) = @_;
    return unless $app->user;
    my $includes = $tmpl->getElementsByName('js_include');
    return unless $includes && @$includes;
    $tmpl->insertBefore(
        $tmpl->createElement('Include', {
            name => 'header_search.tmpl', component => 'Jev',
            jev_header_default => MT::Plugin::Jev::plugin()->get_config_value('jev_header_default', 'system') ? 1 : 0,
        }),
        $includes->[0],
    );
}

sub template_source_search_replace {
    my ($cb, $app, $source) = @_;
    my $include = '<mt:include name="search_option.tmpl" component="Jev">';
    my $count = $$source =~ s{(<ul\b[^>]*\bid="search-bar-advanced-search"[^>]*>[\s\S]*?)(</ul>)}{$1\n$include\n$2}i;
    MT::Plugin::Jev::fail('This version of the MT search screen is not supported by Jev.') unless $count;
    $count = $$source =~ s{<mt:if name="have_results">(\s*<div id="search-bar-replace-fields")}{<mt:if name="jev_can_replace_results">$1}i;
    MT::Plugin::Jev::fail('This version of the MT search screen is not supported by Jev.') unless $count;
}

sub template_param_search_replace {
    my ($cb, $app, $param, $tmpl) = @_;
    $param->{jev_supported} = MT::Plugin::Jev::CMS::supported($param->{object_type}) ? 1 : 0;
    $param->{is_jev} = $param->{jev_supported} && $app->param('is_jev') ? 1 : 0;
    $param->{jev_can_replace_results} = $param->{have_results} && !$param->{is_jev} ? 1 : 0;
    $param->{jev_candidate_limit} = MT::Plugin::Jev::plugin()->get_config_value('jev_candidate_limit', 'system');
    $param->{jev_evaluator} = MT::Plugin::Jev::plugin()->get_config_value('jev_evaluator', 'system');
    if ($param->{is_jev}) {
        $param->{can_replace} = 0;
        $param->{case} = 0;
        $param->{is_regex} = 0;
        $param->{is_limited} = 0;
        $param->{search_options} = ($param->{search_options} || '') . '&amp;is_jev=1';
    }
}

sub post_save {
    my ($cb, $object) = @_;
    require MT::Plugin::Jev::Embedding;
    MT::Plugin::Jev::Embedding->refresh($object);
    return 1;
}

sub post_remove {
    my ($cb, $object) = @_;
    require MT::Plugin::Jev::Embedding;
    MT::Plugin::Jev::Embedding->remove_object($object);
    return 1;
}

1;
