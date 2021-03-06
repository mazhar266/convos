package Convos;
use Mojo::Base 'Mojolicious';

use Cwd ();
use Convos::Core;
use Convos::Util;
use File::HomeDir ();
use Mojo::File 'path';
use Mojo::JSON qw(false true);
use Mojo::Util;

$ENV{CONVOS_PLUGINS} //= 'Convos::Plugin::Paste';

our $VERSION = '0.99_40';

my $ANON_API_CONTROLLER = "Convos::Controller::Anon";

has core => sub {
  my $self = shift;
  my $home = Cwd::abs_path($self->config('home')) || $self->config('home');

  return Convos::Core->new(backend => $self->config('backend'), home => path(split '/', $home));
};

has _api_spec => sub {
  my $self = shift;
  my $file = $self->static->file('convos-api.json');
  die "Could not find convos-api.json in static=@{$self->static->paths}, home=@{[$self->home]})"
    unless $file;
  return Mojo::JSON::decode_json($file->slurp);
};

has _custom_assets => sub { Mojolicious::Static->new };
has _link_cache => sub { Mojo::Cache->new->max_keys($ENV{CONVOS_MAX_LINK_CACHE_SIZE} || 100) };

sub extend_api_spec {
  my ($self, $path) = (shift, shift);

  while (@_) {
    my ($method, $op) = (shift, shift);

    eval "package $ANON_API_CONTROLLER; use Mojo::Base 'Mojolicious::Controller'; 1"
      unless $ANON_API_CONTROLLER->can('new');
    Mojo::Util::monkey_patch($ANON_API_CONTROLLER => $op->{operationId} => delete $op->{cb});

    $op->{'x-mojo-to'} = sprintf 'anon#%s', $op->{operationId};
    $op->{responses}{default}
      ||= {description => 'Error.', schema => {'$ref' => '#/definitions/Error'}};

    $self->_api_spec->{paths}{$path}{$method} = $op;
  }

  return $self;
}

sub startup {
  my $self   = shift;
  my $config = $self->_config;
  my $r      = $self->routes;


  $self->helper(
    delay => sub {
      my $c     = shift;
      my $tx    = $c->render_later->tx;
      my $delay = Mojo::IOLoop->delay(@_);
      $delay->catch(sub { $c->helpers->reply->exception(pop) and undef $tx })->wait;
    }
  );
  $self->_home_in_share unless -d $self->home->rel_file('public');
  $self->defaults(debug => $self->mode eq 'development' ? ['info'] : []);
  $self->routes->namespaces(['Convos::Controller']);
  $self->sessions->cookie_name('convos');
  $self->sessions->default_expiration(86400 * 7);
  $self->sessions->secure(1) if $config->{secure_cookies};
  push @{$self->renderer->classes}, __PACKAGE__;

  # Add basic routes
  $r->get('/')->to(template => 'index')->name('index');
  $r->get('/err/500')->to(cb => sub { die 'Test 500 page' });
  $r->get('/sw' => [format => 'js']);
  $r->get('/custom/asset/*file' => \&_action_custom_asset);
  $r->get('/user/recover/*email/:exp/:check')->to('user#recover')->name('recover');
  $r->get('/user/recover/*email')->to('user#generate_recover_link') if $ENV{CONVOS_COMMAND_LINE};
  $r->websocket('/events')->to('events#start')->name('events');

  $self->_api_spec;
  $self->_plugins;
  $self->_setup_secrets;
  $self->_assets;

  # Autogenerate routes from the OpenAPI specification
  $self->plugin(OpenAPI => {url => delete $self->{_api_spec}});


  $self->hook(
    before_dispatch => sub {
      my $c = shift;

      if (my $base = $c->req->headers->header('X-Request-Base')) {
        $base = Mojo::URL->new($base);
        $c->req->url->base($base);
        $c->app->core->base_url($base);
      }
      else {
        $c->app->core->base_url($c->req->url->to_abs->query(Mojo::Parameters->new)->path('/'));
      }
    }
  );

  $self->core->start;
}

# Used internally to generate dynamic SASS files
sub _action_custom_asset {
  my $c      = shift;
  my $static = $c->app->_custom_assets;
  my $asset  = $static->file(Mojo::Path->new($c->stash('file'))->canonicalize);

  # Can never render 404, since that will make AssetPack croak
  return $c->render(text => "// not found\n", status => 200) unless $asset;
  $c->app->log->info('Loading custom asset: ' . $asset->path);
  $static->serve_asset($c, $asset);
  $c->rendered;
}

sub _assets {
  my $self          = shift;
  my $custom_assets = $self->core->home->child('assets');

  # Skip building on travis
  if ($ENV{TRAVIS_BUILD_ID} or $ENV{CONVOS_COMMAND_LINE}) {
    return $self->helper(asset => sub { });
  }

  $self->plugin(AssetPack => {pipes => [qw(Favicon Vuejs JavaScript Sass Css Combine)]});

  if (-d $custom_assets) {
    $self->log->info("Including files from $custom_assets when building frontend.");
    $self->_custom_assets->paths([$custom_assets]);
    unshift @{$self->asset->store->paths}, $custom_assets;
  }

  $self->asset->pipe('Favicon')
    ->api_key($ENV{REALFAVICONGENERATOR_API_KEY} || 'REALFAVICONGENERATOR_API_KEY=is_not_set')
    ->design({
    desktop_browser => {},
    android_chrome  => {
      picture_aspect => 'shadow',
      manifest       => {name => 'Convos', display => 'standalone', orientation => 'portrait'},
      theme_color    => '#00451D'
    },
    firefox_app => {
      picture_aspect         => 'circle',
      keep_picture_in_circle => 'true',
      circle_inner_margin    => '5',
      background_color       => '#ffffff',
      manifest               => {
        app_name        => 'Convos',
        app_description => 'A better way to IRC',
        developer_name  => 'Nordaaker',
        developer_url   => 'http://nordaaker.com',
      }
    },
    ios =>
      {picture_aspect => 'background_and_margin', margin => '4', background_color => '#ffffff'},
    safari_pinned_tab =>
      {picture_aspect => 'black_and_white', threshold => 60, theme_color => '#00451D'},
    windows => {
      picture_aspect   => "white_silhouette",
      background_color => "#00451D",
      assets           => {
        windows_80_ie_10_tile       => \1,
        windows_10_ie_11_edge_tiles => {small => \0, medium => \1, big => \1, rectangle => \0}
      }
    },
    });
  $self->asset->process('favicon.ico' => 'images/icon.svg');
  $self->asset->process;
}

sub _config {
  my $self   = shift;
  my $config = $self->config;

  if (my $path = $ENV{MOJO_CONFIG}) {
    $config = $path =~ /\.json$/ ? $self->plugin('JSONConfig') : $self->plugin('Config');
  }

  $config->{backend} ||= $ENV{CONVOS_BACKEND} || 'Convos::Core::Backend::File';
  $config->{contact} ||= $ENV{CONVOS_CONTACT} || 'mailto:root@localhost';
  $config->{hide}{$_} = 1 for split /,/, +($ENV{CONVOS_HIDE_ELEMENTS} || '');
  $config->{home} ||= $ENV{CONVOS_HOME}
    ||= path(File::HomeDir->my_home, qw(.local share convos))->to_string;
  $config->{organization_url}  ||= $ENV{CONVOS_ORGANIZATION_URL}  || 'http://convos.by';
  $config->{organization_name} ||= $ENV{CONVOS_ORGANIZATION_NAME} || 'Convos';
  $config->{secure_cookies}    ||= $ENV{CONVOS_SECURE_COOKIES}    || 0;

  $config->{forced_irc_server} ||= $ENV{CONVOS_FORCED_IRC_SERVER} || '';
  $config->{forced_irc_server} = "irc://$config->{forced_irc_server}"
    if $config->{forced_irc_server} and $config->{forced_irc_server} !~ m!^\w+://!;
  $config->{forced_irc_server} = Mojo::URL->new($config->{forced_irc_server});
  $config->{default_server}
    ||= $config->{forced_irc_server}->host_port
    || $ENV{CONVOS_DEFAULT_SERVER}
    || 'chat.freenode.net:6697';

  if ($config->{log_file} ||= $ENV{CONVOS_LOG_FILE}) {
    $self->log->path($config->{log_file});
    delete $self->log->{handle};
  }

  $self->log->info(
    qq(CONVOS_HOME="$ENV{CONVOS_HOME}" # https://convos.by/doc/config.html#convos_home"));

  # public settings
  $config->{settings} = {
    contact           => $config->{contact},
    default_server    => $config->{default_server},
    forced_irc_server => $config->{forced_irc_server}->host ? true : false,
    hide              => $config->{hide} ||= {},
    organization_name => $config->{organization_name},
    organization_url  => $config->{organization_url},
    version           => $self->VERSION || '0.01',
  };

  $config;
}

sub _home_in_share {
  my $self = shift;
  my $rel  = path(qw(auto share dist Convos))->to_string;

  for my $inc (@INC) {
    next if ref $inc or !$inc;
    my $share = path($inc, $rel);
    next unless -d $share and -r _;
    ${$self->home} = $share->to_string;
    $self->static->paths->[0] = $share->child('public')->to_string;
    return $self;
  }

  die "Unable to find $rel in @INC";
}

sub _plugins {
  my $self    = shift;
  my $plugins = $self->config('plugins');
  my @plugins = !$plugins ? () : ref $plugins eq 'ARRAY' ? @$plugins : %$plugins;
  my %uniq;

  unshift @{$self->plugins->namespaces}, 'Convos::Plugin';
  unshift @plugins, split /,/, $ENV{CONVOS_PLUGINS} if $ENV{CONVOS_PLUGINS};
  unshift @plugins, qw(Convos::Plugin::Auth Convos::Plugin::Helpers);

  while (@plugins) {
    my $name = shift @plugins or last;
    my $config = ref $plugins[0] ? shift @plugins : $self->config;
    $self->plugin($name => $config) unless $uniq{$name}++;
  }
}

sub _setup_secrets {
  my $self    = shift;
  my $secrets = $self->config('secrets') || [split /,/, $ENV{CONVOS_SECRETS} || ''];
  my $file    = $self->core->home->child('secrets');

  unless (@$secrets) {
    $secrets = [split /‚/, $file->slurp] if -e $file;
  }
  unless (@$secrets) {
    $secrets = [Mojo::Util::sha1_sum(join ':', rand(), $$, $<, $(, $^X, Time::HiRes::time())];
    path($file->dirname)->make_path unless -d $file->dirname;
    $file->spurt(join ',', @$secrets);
    $self->log->info(
      "CONVOS_SECRETS written to $file # https://convos.by/doc/config.html#convos_secrets");
  }

  $self->secrets($secrets);
}

1;

=encoding utf8

=head1 NAME

Convos - Multiuser chat application

=head1 VERSION

0.99_40

=head1 DESCRIPTION

L<Convos> is a multiuser chat application built with L<Mojolicious>.

It currently support the IRC protocol, but can be extended to support
other protocols as well. Below is a list of the main documentation
starting points for Convos:

=over 2

=item * L<Documentation index|https://convos.by/doc/>

=item * L<Getting started|https://convos.by/doc/getting-started.html>

=item * L<Development guide|https://convos.by/doc/develop.html>

=item * L<REST API reference|http://demo.convos.by/api.html>

=back

=head2 Reference

This is the module and documentation structure of L<Convos>:

=over 2

=item * L<Convos::Core>

=over 2

=item * L<Convos::Core::Backend>

=over 2

=item * L<Convos::Core::Backend::File>

=back

=item * L<Convos::Core::Connection>

=over 2

=item * L<Convos::Core::Connection::Irc>

=back

=item * L<Convos::Core::Dialog>

=item * L<Convos::Core::User>

=back

=item * I<Convos::Controller>

=over 2

=item * L<Convos::Controller::Connection>

=item * L<Convos::Controller::Dialog>

=item * L<Convos::Controller::Events>

=item * L<Convos::Controller::Notifications>

=item * L<Convos::Controller::User>

=back

=back

=head1 ATTRIBUTES

L<Convos> inherits all attributes from L<Mojolicious> and implements
the following new ones.

=head2 core

Holds a L<Convos::Core> object.

=head1 METHODS

L<Convos> inherits all methods from L<Mojolicious> and implements
the following new ones.

=head2 extend_api_spec

  $self->extend_api_spec($path => \%spec);

Used to add more paths to the OpenAPI specification. This is useful
for plugins.

=head2 startup

This method sets up the application.

=head1 COPYRIGHT AND LICENSE

=head2 Material design icons

The icons used are provided by L<Google|https://www.google.com/design/icons>
under the L<CC-BY license|https://creativecommons.org/licenses/by/4.0/>.

=head2 Convos core and frontend

Copyright (C) 2012-2015, Nordaaker.

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

Marcus Ramberg - C<marcus@nordaaker.com>

=cut
