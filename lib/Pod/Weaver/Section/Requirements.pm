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
use Types::Common qw( NonEmptySimpleStr SimpleStr );

use experimental qw( lexical_subs postderef signatures );

use namespace::autoclean;

our $VERSION = 'v0.3.0';

=begin :prelude

=for stopwords metafile

=end :prelude

=head1 SYNOPSIS

In the F<weaver.ini>

    [Requirements]
    header = REQUIREMENTS
    region = :readme

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
    is      => 'lazy',
    isa     => NonEmptySimpleStr,
    default => 'REQUIREMENTS',
);

=option region

When set to a non-empty string, the section will be embedded in a POD region, e.g.

    region = :readme

to make the region available for L<Dist::Zilla::Plugin::UsefulReadme> or L<Pod::Readme>.

=cut

has region => (
    is      => 'lazy',
    isa     => SimpleStr,
    default => '',
);

=option metafile

A file that lists metadata about prerequisites. It defaults to C<cpanfile>.

=cut

has metafile => (
    is      => 'lazy',
    isa     => SimpleStr,
    default => 'cpanfile',
);

sub weave_section( $self, $document, $input ) {

    my $zilla = $input->{zilla};

    unless ($zilla) {
        $self->log_fatal("missing zilla argument");
        return;
    }

    my $runtime = $zilla->prereqs->as_string_hash->{runtime}{requires};

    unless ($runtime) {
      my $file = $input->{filename};

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
    my @metafiles = grep { $_ ne '' } ( $self->metafile, qw( cpanfile META.json META.yml ) );
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
