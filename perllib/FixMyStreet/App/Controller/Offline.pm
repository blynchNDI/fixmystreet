package FixMyStreet::App::Controller::Offline;

use Image::Size;
use JSON::MaybeXS;
use Moose;
use Path::Tiny;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

FixMyStreet::App::Controller::Offline - Catalyst Controller

=head1 DESCRIPTION

Offline pages Catalyst Controller - service worker handling

=head1 METHODS

=cut

sub service_worker : Path("/service-worker.js") {
    my ($self, $c) = @_;
    $c->res->content_type('application/javascript');
}

sub fallback : Local {
    my ($self, $c) = @_;
}

sub manifest: Path("/.well-known/manifest.webmanifest") {
    my ($self, $c) = @_;
    $c->res->content_type('application/manifest+json');

    my $theme = $c->model('DB::ManifestTheme')->find({ cobrand => $c->cobrand->moniker });
    unless ( $theme ) {
        $theme = $c->model('DB::ManifestTheme')->new({
            name => $c->stash->{site_name},
            short_name => $c->stash->{site_name},
            background_colour => '#ffffff',
            theme_colour => '#ffd000',
        });
    }

    $c->forward("_stash_manifest_icons", [ $c->cobrand->moniker ]);

    my $data = {
        name => $theme->name,
        short_name => $theme->short_name,
        background_color => $theme->background_colour,
        theme_color => $theme->theme_colour,
        icons => $c->stash->{manifest_icons},
        lang => $c->stash->{lang_code},
        display => "minimal-ui",
        start_url => "/?pwa",
        scope => "/",
    };
    if ($c->cobrand->can('manifest')) {
        $data = { %$data, %{$c->cobrand->manifest} };
    }

    my $json = encode_json($data);
    $c->res->body($json);
}

sub _stash_manifest_icons : Private {
    my ($self, $c, $cobrand, $ignore_cache_and_defaults) = @_;

    my $key = "manifest_icons:$cobrand";
    # ignore_cache_and_defaults is only used in the admin, so no harm bypassing cache
    my $icons = $ignore_cache_and_defaults ? undef : Memcached::get($key);

    unless ( $icons ) {
        my @icons;
        my $uri = '/theme/' . $cobrand;
        my $theme_path = path(FixMyStreet->path_to('web' . $uri));
        $theme_path->visit(
            sub {
                my ($x, $y, $typ) = Image::Size::imgsize($_->stringify);
                push @icons, {
                    src => join('/', $uri, $_->basename),
                    sizes => join('x', $x, $y),
                    type => $typ eq 'PNG' ? 'image/png' : $typ eq 'GIF' ? 'image/gif' : $typ eq 'JPG' ? 'image/jpeg' : '',
                };
            }
        );

        unless (@icons || $ignore_cache_and_defaults) {
            push @icons,
                { src => "/cobrands/fixmystreet/images/192.png", sizes => "192x192", type => "image/png" },
                { src => "/cobrands/fixmystreet/images/512.png", sizes => "512x512", type => "image/png" };
        }

        $icons = \@icons;

        unless ($ignore_cache_and_defaults) {
            Memcached::set($key, $icons);
        }
    }

    $c->stash->{manifest_icons} = $icons;
}

sub _clear_manifest_icons_cache : Private {
    my ($self, $c, $cobrand ) = @_;

    Memcached::set("manifest_icons:$cobrand", "");
}

__PACKAGE__->meta->make_immutable;

1;
