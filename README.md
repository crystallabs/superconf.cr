# superconf

A small, framework-agnostic, process-wide **configuration registry** for Crystal.

Every tunable — in a library *or* the app using it — is registered once and
becomes reachable from four synchronized surfaces, each value carrying the
**source** it came from:

| Surface | Form (key `screen.resize_interval`) |
|---|---|
| Config key | `screen.resize_interval` (YAML/JSON) |
| Environment variable | `<PREFIX>SCREEN_RESIZE_INTERVAL` |
| Command-line option | `--screen-resize-interval` |
| Runtime | `Superconf.screen_resize_interval` (typed accessor) |

Because the registry is a single process-wide singleton, several independent
components that all register into it — e.g. a terminal library and the
application built on top of it — appear together in **one combined, dumpable
list**.

## Quick start

```crystal
require "superconf"

module Superconf
  option "myapp.refresh", 1.second, description: "Refresh interval"
  option "myapp.workers", 4, validate: ->(n : Int32) { n > 0 }
end

Superconf.app_name   = "myapp"      # ~/.config/myapp/config.yml
Superconf.env_prefix = "MYAPP_"     # MYAPP_MYAPP_REFRESH, ...

Superconf.configure!                # file (if present) + env + CLI, in precedence order

Superconf.myapp_refresh             # => Time::Span (typed, cached read)
Superconf.myapp_refresh = 5.seconds
```

Precedence, low → high: **default < config file < env var < command-line <
runtime assignment**.

## Declaring options

`option key, default, …` infers the value type from `default`. Built-in parsing
covers `Bool`, `Int32`, `Int64`, `Float64`, `String`, `Char`, `Time::Span`, and
any `Enum` (including `@[Flags]`). For other types pass a `parse:` proc. Add a
`validate:` predicate to reject out-of-range values from any source.

`register` is the same thing without the typed accessor (for keys known only at
runtime). `get(key, T)` / `set(key, v)` are the dynamic, string-keyed API used
by the loaders.

## Dumping

`Superconf.dump(io, format)` (or `--dump-config[ FORMAT]` once `configure!` /
`load_args` runs) emits:

* `yaml` (default) and `json` — valid, **re-loadable** config files;
* `env` — a sourceable `export …='value'` script;
* `pretty` — an aligned table showing each value's **source**;
* `report` — rich JSON with full per-option metadata.

## Errors

A single `Superconf::Error` covers unknown keys, type mismatches, unparseable
values, and failed validation — `rescue Superconf::Error` to handle all of them.
