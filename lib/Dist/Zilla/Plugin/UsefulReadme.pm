package Dist::Zilla::Plugin::UsefulReadme;

use v5.20;

use Moose;
with qw(
  Dist::Zilla::Role::AfterBuild
  Dist::Zilla::Role::AfterRelease
  Dist::Zilla::Role::FileGatherer
  Dist::Zilla::Role::FilePruner
  Dist::Zilla::Role::PPI
  Dist::Zilla::Role::PrereqSource
);

use Dist::Zilla 6.003;
use Dist::Zilla::File::InMemory;
use Encode          qw( encode FB_CROAK );
use List::Util 1.33 qw( first none pairs );
use Module::Metadata 1.000015;
use Module::Runtime qw( use_module );
use MooseX::MungeHas;
use Path::Tiny;
use PPI::Token::Pod ();
use Pod::Elemental;
use Pod::Elemental::Transformer::Pod5;
use Pod::Elemental::Transformer::Nester;
use Pod::Elemental::Selectors;
use Types::Common qw( ArrayRef Bool CodeRef Enum NonEmptyStr StrMatch );

use experimental qw( lexical_subs postderef signatures );

use namespace::autoclean;

sub mvp_multivalue_args { qw( sections ) }

sub mvp_aliases { return { section => 'sections', fallback => 'section_fallback' } }

has source => (
    is      => 'lazy',
    isa     => NonEmptyStr,
    builder => sub($self) {
        my $file = $self->zilla->main_module->name;
        ( my $pod = $file ) =~ s/\.pm$/\.pod/;
        return -e $pod ? $pod : $file;
    }
);

sub _source_file($self) {
    my $filename = $self->source;
    return first { $_->name eq $filename } $self->zilla->files->@*;
}

has phase => (
    is      => 'ro',
    isa     => Enum [qw(build release)],
    default => 'build',
);

has location => (
    is      => 'ro',
    isa     => Enum [qw(build root)],
    default => 'build',
);

=option section_fallback

If one of the L</sections> does not exist in the POD, then generate one for the  L<README|/filename>.
It is true by default but cal be disabled, e.g.

    fallback = 0

=cut

has section_fallback => (
    is      => 'ro',
    isa     => Bool,
    default => 1,
);

=option sections

This is a list of C<=head1> sections to be included in the L<README|/filename>.
It can be specified multiple times using the C<section> option.

This can either be a case-insentitive string, or a regex that implicitly matches the entire heading, surrounded by slashes.

The default is equivalent to specifying

    section = name
    section = version
    section = synopsis
    section = description
    section = requirements
    section = installation
    section = /support|bugs/
    section = source
    section = /authors?/
    section = /contributors?/
    section = /copyright|license|copyright and license/
    section = see also

The C<version>, C<requirements> and C<installation> sections are special.
If they do not exist in the module POD, then default values will be used for them unless L</section_fallback> is false.

=cut

has sections => (
    is      => 'ro',
    isa     => ArrayRef [NonEmptyStr],
    builder => sub($self) {
        return [
            map { s/_/ /gr }
              qw(
              name
              version
              synopsis
              description
              requirements
              installation
              /support|bugs/
              source
              /authors?/
              /contributors?/
              /copyright|license|copyright_and_license/
              see_also
              )
        ];

    }
);

my %CONFIG = (
    pod => {
        filename => 'README.pod',
        parser   => sub($pod) { return $pod },
    },
    text => {
        filename => 'README',
        prereqs  => [
            'Pod::Simple::Text' => '3.23',
        ],
    },
    markdown => {
        filename => 'README.mkdn',
        prereqs  => [
            'Pod::Markdown' => '3.000',
        ],
    },
    gfm => {
        filename => 'README.md',
        prereqs  => [
            'Pod::Markdown::Github' => 0,
        ],
    },
);

has type => (
    is      => 'ro',
    isa     => Enum [ keys %CONFIG ],
    default => 'text',
);

has parser_class => (
    is => 'lazy',
    isa => StrMatch[ qr/^[^\W\d]\w*(?:::\w+)*\z/as ], # based on Params::Util _CLASS;
    builder => sub($self) {
       return $CONFIG{ $self->type }{prereqs}[0];
    }
);

has parser => (
    is      => 'lazy',
    isa     => CodeRef,
    builder => sub($self) {
        my $prereqs = $CONFIG{ $self->type }{prereqs};
        my $class = $self->parser_class;
        if ($class ne $prereqs->[0]) {
          use_module($class);
        }
        else {
          foreach my $prereq ( pairs $prereqs->@* ) {
            use_module( $prereq->[0], $prereq->[1] );
          }
        }
        return sub($pod) {
            my $parser = $class->new();
            $parser->output_string( \my $content );
            $parser->parse_characters(1);
            $parser->parse_string_document($pod);
            return $content;
        }
    }
);

has filename => (
    is      => 'lazy',
    isa     => NonEmptyStr,
    builder => sub($self) {
        return $CONFIG{ $self->type }{filename};
    }
);

sub gather_files($self) {
    my $filename = $self->filename;

    if ( ( $self->location eq 'build' )
        && none { $_->name eq $filename } $self->zilla->files->@* )
    {
        my $file = Dist::Zilla::File::InMemory->new(
            {
                content => '', # placeholder
                name    => $self->filename,
            }
        );
        $self->add_file($file);
    }

    return;
}

sub register_prereqs($self) {

    if ( my $prereqs = $CONFIG{ $self->type }{prereqs} ) {
        $self->zilla->register_prereqs(
            {
                phase => 'develop',
                type  => 'requires',
            },
            $prereqs->@*
        );
    }

    return;
}

sub prune_files($self) {

    if ( $self->location eq "root"
        && none { ref($self) eq ref($_) && $_->location ne $self->location && $_->filename eq $self->filename }
        $self->zilla->plugins->@* )
    {
        for my $file ( $self->zilla->files->@* ) {
            next unless $file->name eq $self->filename;
            $self->log_debug( [ 'pruning %s', $file->name ] );
            $self->zilla->prune_file($file);
        }
    }

    return;
}

sub after_build( $self, $build ) {
    # Updating the content of the file after the build has no effect, so we update the actual file on disk
    if ( $self->phase eq 'build' ) {
        my $dir = $self->location eq "build" ? $build->{build_root} : $self->zilla->root;
        $self->_create_readme($dir);
    }
}

sub after_release( $self, $filename ) {
    $self->_create_readme( $self->zilla->root ) if $self->phase eq 'release';
}

sub _create_readme( $self, $dir ) {
    my $file = path( $dir, $self->filename );
    $file->spew_raw( $self->_generate_readme_content );
}

sub _generate_readme_content($self) {
    my $config  = $CONFIG{ $self->type };
    return $self->parser->( $self->_generate_raw_pod );
}

sub _generate_raw_pod($self) {

    # We need to extract the POD from the source file

    my $ppi   = $self->ppi_document_for_file( $self->_source_file );
    my $pods  = $ppi->find('PPI::Token::Pod') or return;
    my $bytes = PPI::Token::Pod->merge( $pods->@* );

    # Then we need to parse the POD and transform that into a list of =head1 sections

    my $doc = Pod::Elemental->read_string($bytes);
    Pod::Elemental::Transformer::Pod5->new->transform_node($doc);

    my $nester = Pod::Elemental::Transformer::Nester->new(
        {
            top_selector      => Pod::Elemental::Selectors::s_command('head1'),
            content_selectors => [
                Pod::Elemental::Selectors::s_flat(),
                Pod::Elemental::Selectors::s_command( [qw(head2 head3 head4 over item back pod cut)] ),
            ],
        },
    );
    $nester->transform_node($doc);

    my @sections = $doc->children->@*;

    my sub _get_section($heading) {
        my $check;
        if ( my ($re) = $heading =~ m|\A/(.+)/\z| ) {
            $check = sub($item) { return $item->content =~ qr/\A(?:${re})\z/i };
        }
        else {
            $check = sub($item) { return fc( $item->content ) eq fc($heading) };
        }

        if (
            my $found =
            first { Pod::Elemental::Selectors::s_command( head1 => $_ ) && $check->($_) } @sections
          )
        {
            return $found->as_pod_string;
        }
        elsif ( $self->section_fallback ) {
            my $method = sprintf( '_generate_pod_for_%s', lc( $heading =~ s/\W+/ /gr ) );
            if ( $self->can($method) ) {
                return $self->$method;
            }
        }
        return;
    }

    return join( "", map { _get_section($_) } $self->sections->@* );
}

sub _generate_pod_for_version($self) {
    my $version = $self->zilla->distmeta->{version};
    return <<"POD_VERSION";
=head1 VERSION

version $version

POD_VERSION
}

sub _generate_pod_for_installation($self) {

  my $zilla = $self->zilla;
  my $arch  = $zilla->name . '-' . $zilla->version;

  my $meta = Module::Metadata->new_from_file( $self->zilla->main_module->name );
  my $pkg  = $meta->name;
  my $pod =<<"POD_INSTALL";
=head1 INSTALLATION

The latest version of this module (along with any dependencies) can be installed from L<CPAN|https://www.cpan.org> with
the C<cpan> tool that is included with Perl:

    cpan ${pkg}

You can also extract the distribution archive and install this module (along with any dependencies):

    cpan .

POD_INSTALL

  my $name = "Makefile.PL"; # default

  my @files = $zilla->files->@*;

  if (my $type = first { $_->name =~ /\A(?:Build|Makefile)\.PL\z/ } @files) {

    $name = $type->name;
    my $cmd  = $name =~ /^Build/ ? "perl Build" : "make";

    $pod .= <<"POD_INSTALL_BUILD";
You can also install this module manually:

    perl ${name}
    ${cmd}
    ${cmd} test
    ${cmd} install

POD_INSTALL_BUILD

  }

  $pod .= <<"POD_INSTALL_DZIL";
If you are working with the source repository, then it may not have a F<${name}> file.  But you can use the
L<Dist::Zilla|https://dzil.org/> tool to build and install this module:

    dzil build
    dzil test
    dzil install --install-command="cpan ."

POD_INSTALL_DZIL

  my $also = "L<How to install CPAN modules|https://www.cpan.org/modules/INSTALL.html>";

  if (my $doc = first { $_->name =~ /\AINSTALL(?:\.(txt|md|mkdn))?\z/ } @files ) {
    $also = sprintf('the F<%s> file included with this distribution', $doc->name);
  }

  $pod .= <<"POD_INSTALL_FINAL";
For more information, see ${also}.

POD_INSTALL_FINAL

  return $pod;
}

sub _generate_pod_for_requirements($self) {

    my $runtime = $self->zilla->prereqs->as_string_hash->{runtime}{requires};

    my sub _module_link($name) {
        my $version = $runtime->{$name};
        return sprintf( '=item * L<%s>%s', $name, $version ? " version ${version} or later" : "" );
    }

    my $lines = join( "\n\n", map { _module_link($_) } sort keys $runtime->%* ) or return;

    my $pod = <<"POD_REQUIREMENTS"
=head1 REQUIREMENTS

This module lists the following modules as runtime dependencies:

=over

POD_REQUIREMENTS
      . $lines . "\n\n=back\n\n";

    return $pod;
}

sub BUILD( $self, $ ) {

    $self->log_fatal("Cannot use location='build' with phase='release'")
      if $self->location eq 'build' and $self->phase eq 'release';

}

__PACKAGE__->meta->make_immutable;

=head1 after:AUTHOR

Some of this code was adapted from similar code in L<Dist::Zilla::Plugin::ReadmeAnyFromPod> and
L<Dist::Zilla::Plugin::Readme::Brief>.

=cut
