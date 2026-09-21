use strict;
use warnings;
use ExtUtils::MakeMaker;
use Getopt::Long qw(GetOptions);
use YAML qw(LoadFile);

my $config = LoadFile('plugins/Jev/config.yaml');
my $version = $config->{version};
GetOptions('version=s' => \$version)
    or die "Usage: perl Makefile.PL [--version VERSION]\n";

WriteMakefile(
    NAME     => $config->{name},
    VERSION  => $version,
    SKIP     => [qw(distdir)],
    DISTNAME => $config->{name},
    # Replace the target archive so removed files cannot survive a rebuild.
    dist     => {PREOP => '$(RM_F) $@'},
);

sub MY::top_targets {
    return <<'MAKE';
build:
	@for source_file in mt-static/plugins/$(NAME)/*.js; do \
		node --check "$$source_file" || exit $$?; \
	done

create_distdir:
	$(RM_RF) $(DISTVNAME)
	$(PERLRUN) "-MExtUtils::Manifest=manicopy,maniread" \
		-e "manicopy(maniread(),'$(DISTVNAME)', '$(DIST_CP)');"

distdir: build create_distdir
	$(NOECHO) $(NOOP)

manifest: build

.PHONY: build create_distdir

MAKE
}
