# roadrunner_nova

Run [Nova](https://github.com/novaframework/nova) applications on
[Roadrunner](https://github.com/arizona-framework/roadrunner).

Nova runs on Cowboy by default, and lets you pick its HTTP server.
`roadrunner_nova` is a Nova server: set it in your config, and your routes,
controllers, plugins, sessions, and WebSocket handlers run on Roadrunner as
they are.

## 🚧 Status

roadrunner_nova is in `0.x`. The core is functional and covered by tests,
but the API may change between minor versions. Pin an exact version
in your deps if you need stability across upgrades.

## Installation

Add it next to `nova` in your `rebar.config` (latest version on
[Hex](https://hex.pm/packages/roadrunner_nova)):

```erlang
{deps, [
    nova,
    roadrunner_nova
]}.
```

Make it Nova's server in your `sys.config`. The rest of the configuration
keeps the shape of Nova's `cowboy_configuration` key:

```erlang
[{nova, [
    {bootstrap_application, my_app},
    {server, roadrunner_nova},
    {cowboy_configuration, #{port => 8080}}
]}].
```

## Configuration

`cowboy_configuration` takes the keys you already use with Nova:

- `ip` and `port`
- `use_ssl => true` with `ssl_port` and `ssl_options` for TLS
- `options => #{compress => false}` to turn off response compression,
  which is on by default as with Cowboy

Add a `roadrunner` key for any other
[Roadrunner listener option](https://hexdocs.pm/roadrunner/roadrunner_listener.html#t:opts/0):

```erlang
{cowboy_configuration, #{
    port => 8080,
    roadrunner => #{max_clients => 10_000, request_timeout => 30_000}
}}
```

## Writing code for any server

Nova hands your controllers and plugins a request map shaped like Cowboy's,
so matching on it (`#{bindings := Bindings}`, `#{method := Method}`, Nova's
`json` and `params`) works on every server.

For anything that sends a response or reads the body, use `nova_req`, which
has the same functions as `cowboy_req`:

```erlang
upload(Req0) ->
    {ok, Body, Req} = nova_req:read_body(Req0),
    ...
```

Code that calls `cowboy_req` for those runs on Cowboy only.

## Sponsors

roadrunner_nova is open source and maintained on personal time. If you or your company find it useful,
consider [sponsoring](https://github.com/sponsors/williamthome).

I also accept coffees ☕

[!["Buy Me A Coffee"](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/williamthome)

<a href="https://github.com/sponsors/williamthome">
  <img
    src="https://raw.githubusercontent.com/williamthome/williamthome/sponsorkit/sponsors.svg"
    alt="Sponsors"
  />
</a>

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](https://github.com/arizona-framework/roadrunner_nova/blob/main/CONTRIBUTING.md) for development setup,
testing guidelines, and contribution workflow.

## License

Copyright (c) 2026 [William Fank Thomé](https://github.com/williamthome)

roadrunner_nova is open-source under the Apache 2.0 License on
[GitHub](https://github.com/arizona-framework/roadrunner_nova).

See [LICENSE.md](https://github.com/arizona-framework/roadrunner_nova/blob/main/LICENSE.md) for more information.
