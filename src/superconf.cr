require "option_parser"
require "./superconf/option"

# See `Superconf::Option` for the high-level overview. This file holds the
# process-wide singleton registry and its load/dump machinery.
#
# It is framework-agnostic: a terminal library and the app that uses it can both
# register into the same registry, and every option then appears together in one
# combined, dumpable list.
module Superconf
  @@options = {} of String => AbstractOption
  @@env_prefix = ""
  @@app_name = "app"

  # Prefix prepended to *derived* environment-variable names (options that did
  # not pass an explicit `env:`). The final application typically sets this once
  # to brand the whole config space, e.g. `Superconf.env_prefix = "CRYSTERM_"`.
  # It is applied lazily, so it affects options registered before it is set too.
  class_property env_prefix : String

  # Application name used by `default_config_path` (e.g. `~/.config/<name>/...`).
  class_property app_name : String

  # Look up an option, or `nil`.
  def self.[]?(key : String) : AbstractOption?
    @@options[key]?
  end

  # Look up an option, raising `Superconf::Error` if it isn't registered.
  def self.[](key : String) : AbstractOption
    @@options[key]? || raise Error.new("unknown config option: #{key.inspect}")
  end

  def self.registered?(key : String) : Bool
    @@options.has_key? key
  end

  # The environment-variable name for *opt*: its explicit `env:` if given, else
  # `env_prefix` + the upper-cased key. Computed lazily so a prefix set after
  # registration still applies.
  def self.env_name(opt : AbstractOption) : String
    opt.explicit_env || (@@env_prefix + opt.key.tr(".-", "__").upcase)
  end

  # Register a new option and return a typed handle whose `#value` you can read
  # directly. The value type `T` is inferred from *default*.
  #
  # *cli* and *group* are derived from *key* unless given; *env* defaults to a
  # lazily-derived name (see `env_name`). For value types beyond the built-ins
  # (`Bool`/`Int*`/`Float64`/`String`/`Char`/`Time::Span`/`Enum`) pass a *parse*
  # proc. *validate* is an optional predicate run against every effective value
  # (and against *default*); a false result raises `Superconf::Error`.
  #
  # Registering a key that already exists raises — keys are unique.
  def self.register(key : String, default : T, *,
                    env : String? = nil, cli : String? = nil,
                    group : String? = nil, description : String = "",
                    parse : Proc(String, T)? = nil,
                    validate : Proc(T, Bool)? = nil) : Option(T) forall T
    raise ArgumentError.new("Config option already registered: #{key.inspect}") if @@options.has_key?(key)
    opt = Option(T).new(
      key,
      default,
      explicit_env: env,
      cli: cli || derive_cli(key),
      group: group || derive_group(key),
      description: description,
      parse: parse,
      validate: validate,
    )
    @@options[key] = opt
    opt
  end

  # Declare a *typed* option: registers it (so it gets an env var, CLI flag,
  # config key, source tracking, and a line in every dump) **and** defines
  # statically-typed accessors `Superconf.<name>` / `Superconf.<name>=`, where
  # `<name>` is the key with dots turned into underscores.
  #
  # This is the ergonomic front door — `Superconf.screen_resize_interval` returns
  # the value directly, with no string key or type argument, reading a cached
  # handle (no hash lookup). Libraries and apps use it by reopening the module:
  #
  # ```
  # module Superconf
  #   option "myapp.refresh", 1.second, description: "Refresh interval"
  # end
  #
  # Superconf.myapp_refresh # => Time::Span (typed)
  # Superconf.myapp_refresh = 5.seconds
  # ```
  #
  # Accepts the same options as `register`, including `parse:` and `validate:`.
  macro option(key, default, *, description = "", env = nil, cli = nil, group = nil, parse = nil, validate = nil)
    {% name = key.split(".").join("_").id %}
    {% const = ("OPT_" + key.split(".").join("_")).id %}
    # Stored in a constant: a constant infers its type from the generic
    # `register` return, so no type annotation is needed.
    {{const}} = register({{key}}, {{default}}, env: {{env}}, cli: {{cli}}, group: {{group}}, description: {{description}}, parse: {{parse}}, validate: {{validate}})

    # Constants initialize lazily — only when first referenced in reachable
    # code. This bare reference (a module-body statement, which *is* eager)
    # forces the registration to run at load time, so an option is always
    # registered even if its accessor is referenced only from code paths the
    # program never runs (otherwise it would vanish from dumps and env/CLI
    # loading). See the "registers eagerly regardless of use" spec.
    {{const}}

    # Typed reader.
    def self.{{name}}
      {{const}}.value
    end

    # Typed writer at `Source::Runtime`.
    def self.{{name}}=(value)
      {{const}}.set value
    end
  end

  # Dynamic, string-keyed read. Prefer the typed accessor (`Superconf.<name>`)
  # in normal code; this is for keys known only at runtime. Raises if the key
  # is unknown or *type* doesn't match how the option was registered.
  def self.get(key : String, type : T.class) : T forall T
    typed(key, type).value
  end

  # Dynamic, string-keyed write at `Source::Runtime` (always wins). Raises on
  # type mismatch. Prefer `Superconf.<name> = ...` in normal code.
  def self.set(key : String, value : T, source : Source = Source::Runtime, origin : String = "API") : Nil forall T
    typed(key, T).set(value, source, origin)
  end

  # Change the *default* of an already-registered option. Unlike `set` (which
  # writes at `Source::Runtime` and thus wins over everything), this writes at
  # `Source::Default` precedence, so a config file / env var / CLI flag / runtime
  # assignment still overrides it. Use it when an application wants a different
  # baseline than a library's registered default — e.g. crysterm choosing a
  # different `tput.read_timeout` — while keeping it user-overridable.
  #
  # It also updates the recorded default (so dumps and `default_string` are
  # consistent). If a higher-precedence source has *already* set the value, the
  # effective value is left untouched (the override stands); only the recorded
  # default changes. Call it early (before `configure!`/`load_*`).
  def self.set_default(key : String, value : T) : Nil forall T
    opt = typed(key, T)
    # `set` validates the value (when it isn't outranked by a higher source);
    # record the new default only after it succeeds, so a value that fails the
    # option's validator raises *without* leaving an invalid default behind.
    opt.set value, Source::Default, "default (set by app)"
    opt.default = value
  end

  # Register an *alias*: a second name (*alias_key*) for an already-registered
  # option (*target_key*). The alias shares the target's value, type, default,
  # parsing and validation, and gets its own config key, env var and CLI flag
  # (derived from *alias_key* unless overridden). Reading or writing either name
  # affects the one shared value — through `get`/`set`, the typed accessor, a
  # config file, an env var or a CLI flag.
  #
  # Use it, like `set_default`, when an option declared by a lower level (a
  # library) is important enough that the application wants to *promote* it under
  # its own name. The library's name keeps working; the app's name becomes an
  # equal surface beside it:
  #
  # ```
  # module Superconf
  #   option "screen.resize_interval", 0.2.seconds # declared by a library
  # end
  #
  # Superconf.register_alias "myapp.refresh", "screen.resize_interval"
  # Superconf.set "myapp.refresh", 1.second             # writes the shared value
  # Superconf.get("screen.resize_interval", Time::Span) # => 1.second
  # # MYAPP_REFRESH / --myapp-refresh / `myapp.refresh:` now work too
  # ```
  #
  # Aliasing an alias is allowed and resolves to the same underlying option.
  # Registering an *alias_key* that already exists raises; an unknown
  # *target_key* raises. Call it early (before `configure!`/`load_*`). Returns
  # the alias handle.
  def self.register_alias(alias_key : String, target_key : String, *,
                          env : String? = nil, cli : String? = nil,
                          group : String? = nil, description : String? = nil) : AbstractOption
    raise ArgumentError.new("Config option already registered: #{alias_key.inspect}") if @@options.has_key?(alias_key)
    root = resolve self[target_key]
    a = root.build_alias(
      alias_key,
      explicit_env: env,
      cli: cli || derive_cli(alias_key),
      group: group || derive_group(alias_key),
      description: description || root.description,
    )
    @@options[alias_key] = a
    a
  end

  # Declare a *typed alias* of *target*: registers an alias named *key* (see
  # `register_alias`) and defines the typed accessors `Superconf.<name>` /
  # `Superconf.<name>=` of value type *type*, where `<name>` is *key* with dots
  # turned into underscores. This is the alias counterpart of `option` — the
  # ergonomic, typed way for an app to promote a lower-level option:
  #
  # ```
  # module Superconf
  #   option_alias "myapp.refresh", "screen.resize_interval", Time::Span
  # end
  #
  # Superconf.myapp_refresh = 1.second # writes the shared value
  # Superconf.myapp_refresh            # => Time::Span
  # ```
  #
  # *type* is the target option's value type. The target must already be
  # registered when this runs (declare the library's `option` first).
  macro option_alias(key, target, type, *, description = nil, env = nil, cli = nil, group = nil)
    {% name = key.split(".").join("_").id %}
    {% const = ("OPT_" + key.split(".").join("_")).id %}
    {{const}} = register_alias({{key}}, {{target}}, env: {{env}}, cli: {{cli}}, group: {{group}}, description: {{description}})
    # Force eager registration (see the `option` macro for why).
    {{const}}

    # Typed reader of the shared value. Reads the cached alias handle directly
    # (no hash lookup), just like `option` — the `.as` is a cheap static
    # downcast, since `register_alias` always yields an `Alias(T)`.
    def self.{{name}} : {{type}}
      {{const}}.as(Alias({{type}})).value
    end

    # Typed writer at `Source::Runtime` of the shared value.
    def self.{{name}}=(value : {{type}})
      {{const}}.as(Alias({{type}})).set(value)
    end
  end

  # The typed option, or a clear error on unknown key / type mismatch. Resolves
  # aliases to the underlying option, so `get`/`set` work through either name.
  private def self.typed(key : String, type : T.class) : Option(T) forall T
    opt = resolve self[key]
    opt.as?(Option(T)) ||
      raise Error.new("config option #{key.inspect} is #{opt.class}, not Option(#{T})")
  end

  # Follow an alias chain to the underlying (non-alias) option.
  private def self.resolve(opt : AbstractOption) : AbstractOption
    while t = opt.alias_target
      opt = t
    end
    opt
  end

  # Iterate every option, ordered by key.
  def self.each(& : AbstractOption ->) : Nil
    sorted.each { |o| yield o }
  end

  private def self.derive_cli(key : String) : String
    "--" + key.tr("._", "--")
  end

  private def self.derive_group(key : String) : String
    key.includes?('.') ? key.split('.', 2)[0] : "general"
  end

  # ---- loaders ---------------------------------------------------------

  # Apply matching environment variables (at `Source::Env`). No-op for any
  # option whose env var is unset. Returns `self` for chaining.
  def self.load_env
    @@options.each_value do |opt|
      name = env_name(opt)
      if v = ENV[name]?
        opt.set_from_string(v, Source::Env, %(env #{name}="#{v}"))
      end
    end
    self
  end

  # Apply command-line options (at `Source::CommandLine`). Recognized flags are
  # matched against the registry; two built-ins are always available:
  #
  # * `--config FILE`        — additionally load a YAML/JSON config file
  # * `--dump-config [FMT]`  — dump configuration (yaml|json|env|pretty|report,
  #   default yaml) and exit
  #
  # Unknown options are ignored so an app's own parsing is left intact. By
  # default the real *argv* is consumed (recognized flags removed); pass
  # `consume: false` to parse a copy non-destructively. Returns `self`.
  def self.load_args(argv : Array(String) = ARGV, *, consume : Bool = true)
    target = consume ? argv : argv.dup
    parser = OptionParser.new
    @@options.each_value do |opt|
      if opt.bool?
        parser.on(opt.cli, opt.description) do
          opt.set_from_string("true", Source::CommandLine, "command line (#{opt.cli})")
        end
        # Only add a `--no-` negation for a long flag. A short or custom flag
        # with no leading `--` (e.g. `-d`) leaves the string unchanged, so
        # registering it again would overwrite the positive handler in
        # OptionParser (handlers are keyed by flag) and make the flag set
        # `false` — leaving no way to turn the option on.
        no = opt.cli.sub("--", "--no-")
        if no != opt.cli
          parser.on(no, "Disable #{opt.key}") do
            opt.set_from_string("false", Source::CommandLine, "command line (#{no})")
          end
        end
      else
        parser.on("#{opt.cli}=VALUE", opt.description) do |v|
          opt.set_from_string(v, Source::CommandLine, "command line (#{opt.cli})")
        end
      end
    end
    parser.on("--config=FILE", "Load configuration from FILE (YAML or JSON)") do |f|
      load_file f
    end
    parser.on("--dump-config [FORMAT]", "Dump configuration (yaml|json|env|pretty|report) and exit") do |fmt|
      dump STDOUT, parse_format(fmt)
      exit
    end
    parser.invalid_option { } # leave unknown flags for the app
    parser.missing_option { }
    parser.parse target
    self
  end

  # Load a YAML document (string or IO) at `Source::ConfigFile`. Accepts nested
  # group mappings (`screen: {resize_interval: 0.5}`) and/or flat dotted keys
  # (`screen.resize_interval: 0.5`). Unknown keys are ignored.
  def self.load_yaml(input : String | IO, origin : String = "YAML")
    apply_any YAML.parse(input), Source::ConfigFile, origin
    self
  end

  # Load a config file by path. JSON is valid YAML, so the same parser handles
  # both `.yml` and `.json`.
  def self.load_file(path : String)
    load_yaml File.read(path), "config file #{path}"
  end

  # The default per-user config path: `$XDG_CONFIG_HOME/<app_name>/config.yml`,
  # or `~/.config/<app_name>/config.yml` when `$XDG_CONFIG_HOME` is unset.
  def self.default_config_path : String
    xdg = ENV["XDG_CONFIG_HOME"]?
    base = xdg && !xdg.empty? ? Path[xdg] : Path.home / ".config"
    (base / @@app_name / "config.yml").to_s
  end

  # Load `default_config_path` if it exists; a no-op otherwise. Returns `self`.
  def self.load_default_file
    path = default_config_path
    load_file path if File.exists? path
    self
  end

  # Opt in to external configuration sources, in precedence order (lowest to
  # highest): a config *file*, then environment variables, then command-line
  # options. If *file* is given it is loaded; otherwise `default_config_path` is
  # loaded when it exists. Pass `file: ""` to skip file loading entirely.
  def self.configure!(file : String? = nil, *, env : Bool = true, args : Bool = true) : Nil
    if file
      load_file file unless file.empty?
    else
      load_default_file
    end
    load_env if env
    load_args if args
  end

  private def self.apply_any(any : YAML::Any, source : Source, origin : String, prefix : String = "") : Nil
    if h = any.as_h?
      h.each do |k, v|
        name = k.as_s? || k.raw.to_s
        key = prefix.empty? ? name : "#{prefix}.#{name}"
        apply_any v, source, origin, key
      end
    else
      return if prefix.empty?
      return if any.raw.nil?
      if opt = @@options[prefix]?
        opt.set_from_string scalar_to_s(any), source, "#{origin} (#{prefix})"
      end
    end
  end

  private def self.scalar_to_s(any : YAML::Any) : String
    raw = any.raw
    raw.is_a?(String) ? raw : raw.to_s
  end

  # ---- dumping ---------------------------------------------------------

  # Dump the full configuration to *io* in *format*. `:yaml`/`:json` produce
  # valid, re-loadable config files; `:env` is a sourceable shell script;
  # `:pretty` is a human table that also shows each value's source; `:report`
  # is rich JSON with full per-option metadata.
  def self.dump(io : IO = STDOUT, format : Format = Format::Yaml) : Nil
    case format
    in Format::Yaml   then dump_yaml io
    in Format::Json   then dump_json io
    in Format::Env    then dump_env io
    in Format::Pretty then dump_pretty io
    in Format::Report then dump_report io
    end
  end

  # The configuration as a re-loadable YAML string.
  def self.to_yaml : String
    String.build { |s| dump_yaml s }
  end

  # The configuration as a re-loadable JSON string.
  def self.to_json : String
    String.build { |s| dump_json s }
  end

  private def self.parse_format(str : String?) : Format
    case str.try(&.downcase)
    when "json"           then Format::Json
    when "env", "sh"      then Format::Env
    when "pretty", "text" then Format::Pretty
    when "report"         then Format::Report
    else                       Format::Yaml
    end
  end

  # Emit a sourceable shell script: one `export <ENV>='value'` per option.
  private def self.dump_env(io : IO) : Nil
    canonical.each do |o|
      io << "export " << env_name(o) << '=' << shell_quote(o.stringify) << '\n'
    end
  end

  # Single-quote *s* for POSIX shells, escaping embedded single quotes.
  private def self.shell_quote(s : String) : String
    "'" + s.gsub("'", %q('\'')) + "'"
  end

  # All options sorted by key.
  private def self.sorted : Array(AbstractOption)
    @@options.values.sort_by!(&.key)
  end

  # Options that own their value (aliases excluded), for the value-listing dumps
  # where emitting the same value under two keys would be redundant. The full
  # set, aliases included, still appears in the `report` dump.
  private def self.canonical : Array(AbstractOption)
    sorted.reject(&.alias_target)
  end

  # Options split into [top-level (no dot)] and [{prefix => options}] for the
  # grouped YAML/JSON dumps. The nesting key is the *key's* first dotted segment,
  # not the option's `group`: `leaf_key` strips that same prefix, so a dump nested
  # this way re-loads back onto the original key. Grouping by `group` instead
  # would silently break the round-trip whenever a custom `group:` differs from
  # the key prefix (the reload would target `group.leaf`, not the real key).
  private def self.grouped_options
    o = canonical
    {o.reject(&.key.includes?('.')), o.select(&.key.includes?('.')).group_by(&.key.split('.', 2).first)}
  end

  private def self.dump_yaml(io : IO) : Nil
    top, grouped = grouped_options
    top_keys = top.map(&.key).to_set
    YAML.build(io) do |y|
      y.mapping do
        top.each do |o|
          y.scalar o.key
          o.emit_yaml y
        end
        grouped.each do |g, gopts|
          # A group whose name equals a top-level scalar key cannot also be a
          # nested mapping (that would emit a duplicate mapping key and lose the
          # scalar on reload). Emit such a group's members flat instead — flat
          # dotted keys stay distinct and `apply_any` re-loads them all the same.
          if top_keys.includes?(g)
            gopts.each do |o|
              y.scalar o.key
              o.emit_yaml y
            end
          else
            y.scalar g
            y.mapping do
              gopts.each do |o|
                y.scalar o.leaf_key
                o.emit_yaml y
              end
            end
          end
        end
      end
    end
  end

  private def self.dump_json(io : IO) : Nil
    top, grouped = grouped_options
    top_keys = top.map(&.key).to_set
    JSON.build(io, indent: "  ") do |j|
      j.object do
        top.each do |o|
          j.field(o.key) { o.emit_json j }
        end
        grouped.each do |g, gopts|
          # See `dump_yaml`: avoid a duplicate field when a group name collides
          # with a top-level key by emitting flat dotted keys for that group.
          if top_keys.includes?(g)
            gopts.each { |o| j.field(o.key) { o.emit_json j } }
          else
            j.field(g) do
              j.object do
                gopts.each { |o| j.field(o.leaf_key) { o.emit_json j } }
              end
            end
          end
        end
      end
    end
  end

  private def self.dump_pretty(io : IO) : Nil
    opts = canonical
    return if opts.empty?
    kw = {opts.max_of(&.key.size), "OPTION".size}.max
    vw = {opts.max_of(&.stringify.size), "VALUE".size}.max
    io << "OPTION".ljust(kw) << "  " << "VALUE".ljust(vw) << "  SOURCE\n"
    io << "-" * kw << "  " << "-" * vw << "  ------\n"
    opts.each do |o|
      io << o.key.ljust(kw) << "  " << o.stringify.ljust(vw) << "  " << o.origin << '\n'
    end
  end

  private def self.dump_report(io : IO) : Nil
    JSON.build(io, indent: "  ") do |j|
      j.array do
        sorted.each do |o|
          j.object do
            j.field "key", o.key
            j.field("value") { o.emit_json j }
            j.field "source", o.source.to_s
            j.field "origin", o.origin
            j.field "default", o.default_string
            j.field "group", o.group
            j.field "env", env_name(o)
            j.field "cli", o.cli
            j.field "description", o.description
            if t = o.alias_target
              j.field "alias_of", t.key
            end
          end
        end
      end
    end
  end
end
