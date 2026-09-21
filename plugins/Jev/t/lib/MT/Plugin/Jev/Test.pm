package MT::Plugin::Jev::Test;

use strict;
use warnings;
use FindBin;
use File::Spec;

our $env;
BEGIN {
    my $mt = $ENV{MT_HOME} or die "Set MT_HOME to a Movable Type 9 checkout.\n";
    my $root = File::Spec->rel2abs("$FindBin::Bin/../../..");
    unshift @INC, "$mt/t/lib", "$mt/lib", "$mt/extlib", "$FindBin::Bin/../lib";
    require MT::Test::Env;
    $env = MT::Test::Env->new(
        PluginPath => ["$root/plugins"],
        PluginSwitch => ['Jev=1'],
        DefaultLanguage => 'en_US',
        AdminThemeId => $ENV{MT_TEST_ADMIN_THEME_ID} || 'admin2025',
    );
    $ENV{MT_CONFIG} = $env->config_file;
}

use MT::Test;

1;
