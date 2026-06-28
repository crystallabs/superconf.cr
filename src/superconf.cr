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

  # Guard `register`/`register_alias` against re-using a key.
  private def self.ensure_unregistered(key : String) : Nil
    raise ArgumentError.new("Config option already registered: #{key.inspect}") if @@options.has_key?(key)
  end

  # The CLI flags `load_args` always registers itself. An option that claimed
  # one of these would have its handler overwritten by the built-in (handlers
  # are keyed by flag string), so it must be rejected up front — see
  # `ensure_cli_free`.
  RESERVED_CLIS = {"--config", "--dump-config"}

  # Raise an `ArgumentError` naming the offending option if any already-registered
  # option matches the given predicate. This is the shared find-and-raise body of
  # the `ensure_*_free` collision guards below, which differ only in *label* (the
  # surface being claimed) and in the predicate that detects the clash; the raised
  # message always ends "… already used by config option <key>".
  private def self.reject_clash(label : String, & : AbstractOption -> Bool) : Nil
    if existing = @@options.each_value.find { |o| yield o }
      raise ArgumentError.new("#{label} already used by config option #{existing.key.inspect}")
    end
  end

  # Guard `register`/`register_alias` against two options claiming the same CLI
  # flag. Distinct keys can still derive (or be given) the same `cli` — e.g.
  # `log.level` and `log_level` both yield `--log-level`, since `derive_cli`
  # maps both `.` and `_` to `-` — and `load_args` keys its `OptionParser`
  # handlers by flag string, so the second registration would silently overwrite
  # the first, leaving one option unreachable from the command line (while env
  # vars and config keys, named independently, would still set both — an
  # inconsistency). Reject the clash up front, like the duplicate-key guard.
  #
  # The same shadowing happens against the built-in flags `--config` and
  # `--dump-config` that `load_args` always registers: an option deriving (or
  # given) one of those would be registered first and then overwritten by the
  # built-in, again leaving it unreachable from the command line. Reject those
  # too.
  private def self.ensure_cli_free(cli : String) : Nil
    if RESERVED_CLIS.includes?(cli)
      raise ArgumentError.new("CLI flag #{cli.inspect} is reserved by Superconf and cannot be used by a config option")
    end
    reject_clash("CLI flag #{cli.inspect}") { |o| o.cli == cli }
  end

  # Guard `register`/`register_alias` against two options claiming the same
  # *explicit* `env:` name. Like a duplicate CLI flag (see `ensure_cli_free`),
  # two options sharing one environment variable can't be set independently —
  # `load_env` reads the single variable into both — and `dump_env` emits two
  # `export FOO=…` lines for it, so sourcing then reloading the env dump silently
  # collapses both options to one value, breaking the dump→reload round-trip.
  #
  # Only *explicit* names are checked here. A *derived* name (prefix + key) can
  # still collide with another derived one — see `ensure_derived_env_free`, which
  # catches that case separately. An explicit-vs-derived clash, by contrast,
  # depends on `env_prefix` (set lazily, possibly after registration), so it
  # can't be detected reliably; explicit-vs-explicit is prefix-independent and is
  # the part we can catch cleanly here.
  private def self.ensure_env_free(env : String?) : Nil
    return unless env
    reject_clash("environment variable #{env.inspect}") { |o| o.explicit_env == env }
  end

  # Guard two *derived* env names from colliding. Unlike a derived *CLI* clash
  # (caught by `ensure_cli_free`), a derived env clash is **not** implied by a CLI
  # clash: `env_name` upper-cases the key (`derived_env_suffix`) while
  # `derive_cli` preserves case, so two keys differing only in letter case —
  # e.g. `case.foo` vs `casE.foo` — derive the *same* env var (`CASE_FOO`) but
  # *different* CLI flags (`--case-foo` vs `--casE-foo`). Left unguarded,
  # `load_env` would read the one variable into *both* options, and `dump_env`
  # would emit two `export CASE_FOO=…` lines, so sourcing then reloading the env
  # dump collapses both options to one value — exactly the dump→reload breakage
  # `ensure_env_free` prevents for explicit names. The check is
  # prefix-independent (both derived names share the lazy `env_prefix`), so it
  # holds regardless of when `env_prefix` is set. Only options that *derive*
  # their env (no explicit `env:`) are compared; an explicit name sidesteps the
  # collision and is the documented escape hatch.
  private def self.ensure_derived_env_free(key : String) : Nil
    suffix = derived_env_suffix(key)
    reject_clash("environment variable #{(@@env_prefix + suffix).inspect} (derived from key #{key.inspect})") do |o|
      o.explicit_env.nil? && derived_env_suffix(o.key) == suffix
    end
  end

  # The suffix `env_name` derives from a key (before the lazy `env_prefix`): the
  # key upper-cased with `.` and `-` folded to `_`.
  private def self.derived_env_suffix(key : String) : String
    key.tr(".-", "__").upcase
  end

  # The environment-variable name for *opt*: its explicit `env:` if given, else
  # `env_prefix` + the derived suffix. Computed lazily so a prefix set after
  # registration still applies.
  def self.env_name(opt : AbstractOption) : String
    opt.explicit_env || (@@env_prefix + derived_env_suffix(opt.key))
  end

  # Resolve the CLI flag and (optional) explicit env name for a freshly
  # registered option or alias keyed *key*, and run the collision guards. Shared
  # by `register` and `register_alias` so the derive-then-guard sequence lives in
  # one place. Returns the resolved `{cli, env}`.
  #
  # An *empty* explicit override is treated as no override at all (derive
  # instead), the same way `nil` is. A blank `env:` would otherwise become the
  # option's env-var *name* — unusable: `ENV[""]` is never set, `load_env` can
  # never reach the option, and `dump_env` emits the invalid line
  # `export ='value'`, breaking the env dump's round-trip. A blank `cli:`
  # likewise yields an unusable, valueless flag (`OptionParser.on("=VALUE")`).
  # Folding "" into the derived name keeps the surfaces working and matches the
  # library's "present-but-empty means unset" philosophy.
  private def self.derive_surfaces(key : String, cli : String?, env : String?) : {String, String?}
    the_cli = cli.presence || derive_cli(key)
    the_env = env.presence
    ensure_cli_free the_cli
    ensure_env_free the_env
    ensure_derived_env_free key if the_env.nil?
    {the_cli, the_env}
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
    ensure_unregistered key
    the_cli, the_env = derive_surfaces(key, cli, env)
    opt = Option(T).new(
      key,
      default,
      explicit_env: the_env,
      cli: the_cli,
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
    ensure_unregistered alias_key
    root = resolve self[target_key]
    the_cli, the_env = derive_surfaces(alias_key, cli, env)
    a = root.build_alias(
      alias_key,
      explicit_env: the_env,
      cli: the_cli,
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

  # Does *opt* carry a `String` value (directly, or through an alias)? An empty
  # CLI value is a legitimate value only for a String option; for any other type
  # parsing "" raises, so `load_args` treats the two cases differently.
  private def self.string_valued?(opt : AbstractOption) : Bool
    resolve(opt).is_a?(Option(String))
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
      # Treat a *present but empty* env var (e.g. `MYAPP_THREADS=`) like an
      # absent one — a no-op — but only for a typed, non-String option. An empty
      # env var is the shell-conventional "not really set", and commonly appears
      # unintentionally (an exported-but-unset var, a CI that injects empty
      # values). Parsing "" into a typed, non-String option (Int/Float/Bool/
      # Char/Time::Span/Enum) raises, which would abort the whole `configure!`
      # over a benign empty variable.
      #
      # A *String* option, however, still takes "" as a real value, exactly as
      # `load_args` does for `--flag=` and `apply_any` does for `key: ""`. Before
      # this, the three loaders disagreed: a String option could be set to ""
      # from the command line or a config file but never from the environment,
      # so `MYAPP_TITLE=` was silently dropped instead of clearing the value.
      if (v = ENV[name]?) && (!v.empty? || string_valued?(opt))
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
    # Flags OptionParser reported as given without their required value. The
    # `missing_option` handler below is a no-op — a recognized flag missing its
    # value is ignored rather than aborting the program — but OptionParser still
    # calls the value handler afterwards with an empty string. Parsing "" into a
    # typed (non-String) option would raise and kill the whole program, so
    # record the offending flags here and skip them in the handler.
    missing = Set(String).new
    # Every option's *primary* flag. A bool's auto-generated `--no-` negation is
    # suppressed when it collides with one of these (see below).
    primary_clis = @@options.values.map(&.cli).to_set
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
        # Also suppress it when the negation collides with another option's
        # *primary* flag — e.g. `option "color", true` derives `--no-color`,
        # which is exactly the primary flag a `no_color` option derives (the
        # real NO_COLOR convention). Since OptionParser keys handlers by flag,
        # registering the negation would non-deterministically clobber (per
        # registration order) the explicit option's handler, so `--no-color`
        # might flip `color` instead of setting `no_color`. An explicit flag
        # always wins over a derived negation.
        if no != opt.cli && !primary_clis.includes?(no)
          parser.on(no, "Disable #{opt.key}") do
            opt.set_from_string("false", Source::CommandLine, "command line (#{no})")
          end
        end
      else
        parser.on("#{opt.cli}=VALUE", opt.description) do |v|
          # An empty value reaches here in two shapes, both of which would
          # crash a typed (non-String) option by force-parsing "" into its
          # type (`"".to_i`, `"".to_f`, an empty enum, etc. all raise):
          #   * a *missing* value — a trailing `--flag` with nothing after it,
          #     recorded in `missing` by the `missing_option` handler; and
          #   * an *explicit* empty assignment — `--flag=` — where the value is
          #     present but empty, so `missing_option` never fires and the flag
          #     is absent from `missing`.
          # Skip both for a non-String option, mirroring `load_env`'s "an empty
          # value means unset" rule, so one stray empty CLI argument (e.g.
          # `--workers=$VAR` with `$VAR` unset) can't abort the whole parse. For
          # a String option an explicit `--flag=` still sets "" — a real value —
          # while a truly missing value is still skipped.
          next if v.empty? && (missing.includes?(opt.cli) || !string_valued?(opt))
          opt.set_from_string(v, Source::CommandLine, "command line (#{opt.cli})")
        end
      end
    end
    parser.on("--config=FILE", "Load configuration from FILE (YAML or JSON)") do |f|
      next if f.empty? # `--config` with no path: nothing to load (see `missing`)
      load_file f
    end
    parser.on("--dump-config [FORMAT]", "Dump configuration (yaml|json|env|pretty|report) and exit") do |fmt|
      dump STDOUT, parse_format(fmt)
      exit
    end
    parser.invalid_option { } # leave unknown flags for the app
    parser.missing_option { |flag| missing << flag }
    parser.parse target
    self
  end

  # Load a YAML document (string or IO) at `Source::ConfigFile`. Accepts nested
  # group mappings (`screen: {resize_interval: 0.5}`) and/or flat dotted keys
  # (`screen.resize_interval: 0.5`). Unknown keys are ignored.
  def self.load_yaml(input : String | IO, origin : String = "YAML")
    # Wrap a *syntactically* malformed document in `Error`: the class docs
    # promise that rescuing `Superconf::Error` handles every malformed-config
    # case, a config file included, so a raw `YAML::ParseException` must not
    # leak out. `apply_any`'s own value errors are already `Error`s and pass
    # through unchanged.
    doc = begin
      YAML.parse input
    rescue ex : YAML::ParseException
      raise Error.new("cannot parse #{origin}: #{ex.message}")
    end
    apply_any doc, Source::ConfigFile, origin
    self
  end

  # Load a config file by path. JSON is valid YAML, so the same parser handles
  # both `.yml` and `.json`.
  def self.load_file(path : String)
    # Wrap a filesystem error (missing, unreadable, permission denied) in
    # `Error`, just as `load_yaml` wraps a parse error: the class docs promise
    # that rescuing `Superconf::Error` handles every malformed-config case, a
    # config file included, so a raw error must not leak out of an
    # explicitly-named file (`--config FILE`, `configure!(file:)`, this call).
    # Rescue `IO::Error`, not just `File::Error`: a missing/unreadable file
    # raises `File::Error` (a subclass), but pointing at a *directory* (e.g.
    # `--config ~/.config/myapp/`) raises a plain `IO::Error` ("Is a directory"),
    # which `File::Error` would miss — letting it leak.
    content = begin
      File.read(path)
    rescue ex : IO::Error
      raise Error.new("cannot read config file #{path}: #{ex.message}")
    end
    load_yaml content, "config file #{path}"
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
      # Only a *scalar* is a settable leaf value. A mapping is handled by the
      # branch above (it recurses); a sequence is the remaining structural
      # non-scalar — ignore it just like a mapping, instead of letting it fall
      # through to `scalar_to_s`, which would stringify the array's Crystal
      # inspect form (e.g. `[1, 2, 3]`) and silently store *that* into a String
      # option (or raise for a typed one). A quoted scalar that merely *looks*
      # like a list (`key: "[1,2,3]"`) is a real scalar and still applies.
      return if any.as_a?
      if opt = @@options[prefix]?
        s = scalar_to_s(any)
        # Treat a *present but empty* scalar (`key: ""`) as unset for a typed,
        # non-String option, exactly as `load_env` and `load_args` do for an
        # empty env var / `--flag=`. Force-parsing "" into a non-String type
        # (Int/Float/Bool/Char/Time::Span/Enum) raises, which would abort the
        # whole config load over one benign empty value — e.g. a templated
        # config (`threads: "${THREADS}"`) where the variable expanded to
        # nothing. A `key:` with no value (YAML null) is already skipped above;
        # this extends the same leniency to an explicit empty string. A String
        # option still accepts "" as a real value, just as `--flag=` sets "".
        return if s.empty? && !string_valued?(opt)
        opt.set_from_string s, source, "#{origin} (#{prefix})"
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

  # A leaf in a grouped dump: an option emitted under its full *key* — either a
  # top-level (no-dot) option, or a member of a group whose name collides with a
  # top-level key (see `dump_entries`).
  private record DumpLeaf, key : String, opt : AbstractOption
  # A nested group in a grouped dump: *opts* emitted under *name* by `leaf_key`.
  private record DumpGroup, name : String, opts : Array(AbstractOption)

  # The ordered emit plan shared by the grouped YAML/JSON dumps, so the
  # top-vs-group decision lives in exactly one place. The nesting key is the
  # *key's* first dotted segment, not the option's `group`: `leaf_key` strips
  # that same prefix, so a dump nested this way re-loads back onto the original
  # key. Grouping by `group` instead would silently break the round-trip
  # whenever a custom `group:` differs from the key prefix (the reload would
  # target `group.leaf`, not the real key).
  #
  # A group whose name equals a top-level scalar key cannot also be a nested
  # mapping (that would emit a duplicate mapping key and lose the scalar on
  # reload), so its members are emitted flat instead — flat dotted keys stay
  # distinct and `apply_any` re-loads them all the same.
  private def self.dump_entries : Array(DumpLeaf | DumpGroup)
    o = canonical
    top, dotted = o.partition { |opt| !opt.key.includes?('.') }
    top_keys = top.map(&.key).to_set
    entries = Array(DumpLeaf | DumpGroup).new
    top.each { |opt| entries << DumpLeaf.new(opt.key, opt) }
    dotted.group_by(&.key.split('.', 2).first).each do |g, gopts|
      if top_keys.includes?(g)
        gopts.each { |opt| entries << DumpLeaf.new(opt.key, opt) }
      else
        entries << DumpGroup.new(g, gopts)
      end
    end
    entries
  end

  private def self.dump_yaml(io : IO) : Nil
    YAML.build(io) do |y|
      y.mapping do
        dump_entries.each do |e|
          case e
          in DumpLeaf
            y.scalar e.key
            e.opt.emit_yaml y
          in DumpGroup
            y.scalar e.name
            y.mapping do
              e.opts.each do |o|
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
    JSON.build(io, indent: "  ") do |j|
      j.object do
        dump_entries.each do |e|
          case e
          in DumpLeaf
            j.field(e.key) { e.opt.emit_json j }
          in DumpGroup
            j.field(e.name) do
              j.object do
                e.opts.each { |o| j.field(o.leaf_key) { o.emit_json j } }
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
