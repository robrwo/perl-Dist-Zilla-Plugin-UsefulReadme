package Pod::Weaver::Section::Requirements;

# ABSTRACT: generate POD with the runtime requirements

use v5.20;

use Moose;
with 'Pod::Weaver::Role::Section';

use List::Util qw( first );
use MooseX::MungeHas;
use Perl::PrereqScanner 1.024;
use Pod::Elemental::Element::Nested;
use Pod::Elemental::Element::Pod5::Command;
use Pod::Elemental::Element::Pod5::Ordinary;
use Pod::Elemental::Element::Pod5::Region;
use Types::Common qw( Bool NonEmptySimpleStr SimpleStr );

use experimental qw( lexical_subs postderef signatures );

use namespace::autoclean;

our $VERSION = 'v0.4.4';

=begin :prelude

=for stopwords metafile

=end :prelude

=head1 SYNOPSIS

In the F<weaver.ini>:

    [Requirements]
    header = REQUIREMENTS
    region = :readme

Or in the F<dist.ini> for L<Dist::Zilla>:

    [PodWeaver]
    [%PodWeaver]
    Requirements.header = REQUIREMENTS
    Requirements.region = :readme

=head1 DESCRIPTION

This is a L<Pod::Weaver> plugin to add a section with the runtime requirements.

=head1 KNOWN ISSUES

When this is used to insert a section into the POD of a module, that it will only show the requirements for that module,
and not the requirements of all of the modules in distribution.  To show the later, it must be run after the build phase
from L<Dist::Zilla> though a plugin such as L<Dist::Zilla::Plugin::UsefulReadme>.

=option header

The header to use. It defaults to "REQUIREMENTS".

=cut

has header => (
    is      => 'rw',
    isa     => NonEmptySimpleStr,
    default => 'REQUIREMENTS',
);

=option region

When set to a non-empty string, the section will be embedded in a POD region, e.g.

    region = :readme

to make the region available for L<Dist::Zilla::Plugin::UsefulReadme> or L<Pod::Readme>.

=cut

has region => (
    is      => 'rw',
    isa     => SimpleStr,
    default => '',
);

=option metafile

A file that lists metadata about prerequisites. It defaults to C<cpanfile>.

=cut

has metafile => (
    is      => 'rw',
    isa     => SimpleStr,
    default => 'cpanfile',
);

=option all_modules

When true, this section will be added to all modules in the distribution, and not just the main module.

When false (default), this section will only be added to the main module.

=cut

has all_modules => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

=option guess_prereqs

If the runtime prerequsites are not available from L<Dist::Zilla>, then when this attribute is true, this plugin will
use L<Perl::PrereqScanner> to guess the prerequisites.

This was added in version v0.4.4, and is now false by default. (Previous versions guessed automatically.)

=cut

has guess_prereqs => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

sub weave_section( $self, $document, $input ) {

    my $zilla = $input->{zilla};

    unless ($zilla) {
        $self->log_fatal("missing zilla argument");
        return;
    }

    if ( $zilla && !$self->all_modules ) {
        return if $zilla->main_module->name ne $input->{filename};
    }

    if ( my $stash = $zilla ? $zilla->stash_named('%PodWeaver') : undef ) {
        $stash->merge_stashed_config($self);
    }

    my $runtime = $zilla->prereqs->as_string_hash->{runtime}{requires};

    if ( !$runtime && $self->guess_prereqs ) {
      my $scanner = Perl::PrereqScanner->new;
      my $prereqs = $scanner->scan_ppi_document($input->{ppi_document} );
      $runtime = $prereqs->as_string_hash;
    }

    return unless $runtime;

    my sub _module_link($name) {
        my $version = $runtime->{$name};

        my $text = "L<${name}>";
        $text .= " version ${version} or later" if $version;

        return (
            Pod::Elemental::Element::Pod5::Command->new(
                {
                    command => 'item',
                    content => '*'
                }
            ),
            Pod::Elemental::Element::Pod5::Ordinary->new( { content => $text } )
        );
    }

    my @links = ( map { _module_link($_) } sort keys $runtime->%* ) or return;

    my $res = Pod::Elemental::Element::Nested->new(
        {
            type     => 'command',
            command  => 'head1',
            content  => $self->header,
            children => [
                Pod::Elemental::Element::Pod5::Ordinary->new(
                    { content => "This module lists the following modules as runtime dependencies:" }
                ),
                Pod::Elemental::Element::Pod5::Command->new(
                    {
                        command => 'over',
                        content => '4',
                    }
                ),
                @links,
                Pod::Elemental::Element::Pod5::Command->new(
                    {
                        command => 'back',
                        content => '',
                    }
                )
            ]
        }
    );

    my %files = map { $_->name => 1 } $zilla->files->@*;
    my @metafiles = grep { $_ ne '' } ( $self->metafile, qw( cpm.yml cpanfile META.json META.yml ) );
    if ( my $file = first { $files{$_} } @metafiles ) {
        push $res->children->@*,
          Pod::Elemental::Element::Pod5::Ordinary->new(
            { content => "See the F<${file}> file for the full list of prerequisites." } );
    }

    if ( my $name = $self->region ) {

        push $document->children->@*,
          Pod::Elemental::Element::Pod5::Region->new(
            {
                format_name => $name =~ s/^://r,
                is_pod      => 1,
                content     => '',
                children    => [$res],
            }
          );

    }
    else {
        push $document->children->@*, $res;
    }

}

__PACKAGE__->meta->make_immutable;

=for Pod::Coverage weave_section

=head1 SEE ALSO

L<Pod::Weaver::Section::Requires>

=head1 prepend:SUPPORT

Only the latest version of this module will be supported.

This module requires Perl v5.20 or later.  Future releases may only support Perl versions released in the last ten
years.

=head2 Reporting Bugs and Submitting Feature Requests

=head1 append:SUPPORT

If the bug you are reporting has security implications which make it inappropriate to send to a public issue tracker,
then see F<SECURITY.md> for instructions how to report security vulnerabilities.

=cut
