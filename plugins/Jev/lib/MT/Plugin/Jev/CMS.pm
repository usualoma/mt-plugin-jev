package MT::Plugin::Jev::CMS;

use strict;
use warnings;
use Scalar::Util qw(blessed);
use MT::Plugin::Jev;

sub supported { defined $_[0] && $_[0] =~ /\A(?:entry|page|content_data)\z/ }

my $installed;
sub init_app {
    return 1 if $installed;
    require MT::CMS::Search;
    my $original = \&MT::CMS::Search::search_replace;
    no warnings 'redefine';
    # Registering a second methods.search_replace handler is additive in MT:
    # it would run the core search again, even after rejecting a replacement.
    *MT::CMS::Search::search_replace = sub {
        my ($app, @args) = @_;
        return $original->($app, @args) unless MT->component('Jev') && $app->mode eq 'search_replace';
        return search_replace($app, $original, @args);
    };
    $installed = 1;
    return 1;
}

sub search_replace {
    my ($app, $original) = @_;
    return $original->($app) unless $app->param('is_jev');

    my ($result, $error);
    {
        local $@;
        eval {
            MT::Plugin::Jev::fail('Replacement is unavailable while Jev is enabled.') if $app->param('do_replace');
            my $type = $app->param('search_type') || $app->param('_type');
            unless ($type) {
                my $tabs = $app->search_apis($app->param('blog_id') ? 'blog' : 'system');
                $type = $tabs && @$tabs ? $tabs->[0]{key} : '';
            }
            MT::Plugin::Jev::fail('Jev supports entries, pages and content data.') unless supported($type);
            my $execute = $app->param('do_search') || $app->param('show_all')
                || defined $app->param('publish_status') || $app->param('my_posts')
                || ($app->param('filter') && $app->param('filter_val'));
            if ($execute) {
                my $condition = $app->param('search') // '';
                $condition =~ s/\A\s+|\s+\z//g;
                MT::Plugin::Jev::fail('Enter a natural-language search condition.') unless length $condition;
                my $config = MT::Plugin::Jev::config();
                MT::Plugin::Jev::fail('Configure a TypeSafe API key in the Jev plugin settings.')
                    if $config->{jev_evaluator} eq 'jev' && !$config->{jev_api_key};
                MT::Plugin::Jev::fail('Configure an OpenAI API key in the Jev plugin settings.') unless $config->{openai_api_key};
                require MT::Plugin::Jev::Search;
                $result = with_params($app, {
                    show_all => 1, case => 0, is_regex => 0, quicksearch => 0, is_limited => 0,
                    replace => undef, search => $condition,
                }, sub { MT::Plugin::Jev::Search->run($app, $config, $type, $condition, $original) });
            } else {
                $result = $original->($app);
            }
            1;
        } or $error = $@;
    }
    if ($error) {
        die $error unless blessed($error) && $error->isa('MT::Plugin::Jev::Error');
        # Render an unsearched form: never show partial results as complete.
        $result = with_params($app, {
            do_search => 0, show_all => 0, do_replace => 0, replace => undef,
            publish_status => undef, my_posts => 0, filter => undef, filter_val => undef,
            quicksearch => 0, case => 0, is_regex => 0,
        }, sub { $original->($app) });
        $result->param({error => $error->message, searched => 0, have_results => 0, have_more => 0})
            if ref $result && $result->can('param');
    }
    return $result;
}

sub with_params {
    my ($app, $values, $code) = @_;
    my $query = $app->param;
    my %saved = map { $_ => [$app->multi_param($_)] } keys %$values;
    for my $key (keys %$values) {
        $query->delete($key);
        $query->param($key, $values->{$key}) if defined $values->{$key};
    }
    my ($result, $error);
    {
        local $@;
        eval { $result = $code->(); 1 } or $error = $@;
    }
    for my $key (keys %saved) {
        $query->delete($key);
        $query->param($key, @{ $saved{$key} }) if @{ $saved{$key} };
    }
    die $error if $error;
    return $result;
}

1;
