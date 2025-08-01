package Pod::Weaver::Section::Requirements;

# ABSTRACT: generate POD with the runtime requirements

use v5.20;

use Moose;
with 'Pod::Weaver::Role::Section';

use MooseX::MungeHas;
use Pod::Elemental::Element::Nested;
use Types::Common qw( NonEmptySimpleStr SimpleStr );

use experimental qw( lexical_subs postderef signatures );

use namespace::autoclean;

our $VERSION = 'v0.1.0';

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

sub weave_section( $self, $document, $input ) {

    my $zilla = $input->{zilla};

    unless ($zilla) {
        $self->log_fatal("missing zilla argument");
        return;
    }

    my $runtime = $zilla->prereqs->as_string_hash->{runtime}{requires};

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

=head1 SEE ALSO

L<Pod::Weaver::Section::Requires>

=cut
