require "json"
require "yaml"

# Superconf — a small, framework-agnostic, process-wide configuration registry.
#
# Every tunable (in a library or an app) is registered once with `Superconf.option`
# (or `Superconf.register`), after which it is reachable from four surfaces kept
# in sync automatically:
#
# * a **config key**, e.g. `screen.resize_interval`
# * an **environment variable**, derived as `<PREFIX>SCREEN_RESIZE_INTERVAL`
# * a **command-line option**, derived as `--screen-resize-interval`
# * the **runtime value**, via a typed accessor (`Superconf.screen_resize_interval`)
#   or `Superconf.get`
#
# Each effective value also carries a `Source` (and a human-readable `origin`)
# describing *where it came from*.
#
# Because the registry is a single process-wide singleton, several independent
# components (e.g. a terminal library and the app using it) that all register
# into it appear together in one combined, dumpable list.
module Superconf
  # Raised for any configuration error: an unknown key, a type mismatch, or a
  # value that can't be parsed for its option. Rescue this one type to handle
  # all malformed-config cases (e.g. a bad env var or config file).
  class Error < Exception
  end

  # Where an option's current value came from. Ordered by precedence: a higher
  # member overrides a lower one. So a command-line flag beats an environment
  # variable, which beats a config file, which beats the built-in default; an
  # explicit runtime assignment always wins.
  enum Source
    Default     # the value passed to `register`
    ConfigFile  # loaded from a YAML/JSON config file
    Env         # an environment variable
    CommandLine # a `--flag` on the command line
    Runtime     # assigned programmatically via the API
  end

  # Output format understood by `Superconf.dump`.
  enum Format
    Yaml   # valid, re-loadable YAML config
    Json   # valid, re-loadable JSON config
    Env    # sourceable shell script of `export <PREFIX>…=…` lines
    Pretty # human-readable aligned table, including each value's source
    Report # rich JSON: value + source + full metadata for every option
  end

  # Non-generic base so options of different value types can share one
  # collection. Typed behavior lives in `Option(T)`.
  abstract class AbstractOption
    getter key : String
    # An explicit env-var name, or `nil` to derive one lazily from the registry
    # prefix + key (see `Superconf.env_name`). Kept lazy so the prefix can be set
    # after options are registered (e.g. by the final app, across libraries).
    getter explicit_env : String?
    getter cli : String
    getter group : String
    getter description : String
    getter source : Source = Source::Default
    getter origin : String = "default"

    def initialize(@key, @explicit_env, @cli, @group, @description)
    end

    # Current value rendered as the string used across env/CLI/config/dumps.
    abstract def stringify : String

    # The registered default, rendered as a string.
    abstract def default_string : String

    # Parse *str* and store it, honoring precedence (see `Source`).
    abstract def set_from_string(str : String, source : Source, origin : String) : Nil

    # Is the value type `Bool`? Governs `--flag` / `--no-flag` generation.
    abstract def bool? : Bool

    # Emit the current value as a native YAML scalar.
    abstract def emit_yaml(yaml : YAML::Builder) : Nil

    # Emit the current value as a native JSON value.
    abstract def emit_json(json : JSON::Builder) : Nil

    # Key with its leading `<group>.` stripped, for grouped dumps. A key
    # without a dot is returned unchanged.
    def leaf_key : String
      key.includes?('.') ? key.split('.', 2)[1] : key
    end
  end

  # One registered, typed configuration option.
  #
  # `T` may be `Bool`, `Int32`, `Int64`, `Float64`, `String`, `Char`,
  # `Time::Span`, or any `Enum` (including `@[Flags]` enums). Any other type is
  # supported by passing an explicit `parse:` proc to `register`.
  class Option(T) < AbstractOption
    getter default : T
    getter value : T

    # Change the recorded default (used by `Superconf.set_default`). Does not by
    # itself change the effective `value`; the caller also `set`s at `Default`
    # precedence so config/env/CLI/runtime still win.
    def default=(@default : T)
    end

    def initialize(key : String, @default : T, *, explicit_env : String?, cli : String,
                   group : String, description : String,
                   @parse : Proc(String, T)? = nil,
                   @validate : Proc(T, Bool)? = nil)
      @value = @default
      super(key, explicit_env, cli, group, description)
      # Catch a bad default at declaration time, not on first use.
      if v = @validate
        raise Error.new("default value #{@default.inspect} fails validation for option #{key.inspect}") unless v.call(@default)
      end
    end

    # Typed assignment. Applies only if *source* is at least as authoritative
    # as the source of the current value (see `Source`); a value that wins
    # must also pass the option's `validate` predicate, if any.
    def set(value : T, source : Source = Source::Runtime, origin : String = "API") : Nil
      return if source < @source
      if v = @validate
        raise Error.new("invalid value #{value.inspect} for option #{@key} (#{origin})") unless v.call(value)
      end
      @value = value
      @source = source
      @origin = origin
    end

    def set_from_string(str : String, source : Source, origin : String) : Nil
      # Skip values that a higher-precedence source already set: don't parse
      # or validate something we'd discard anyway (so a bad value in a file
      # that a CLI flag overrides never trips an error).
      return if source < @source
      value = begin
        cast str
      rescue ex
        raise Error.new("cannot parse #{str.inspect} for option #{key.inspect} (#{origin}): #{ex.message}")
      end
      set value, source, origin
    end

    def stringify : String
      render @value
    end

    def default_string : String
      render @default
    end

    def bool? : Bool
      {% if T == Bool %} true {% else %} false {% end %}
    end

    # Numeric/bool values are emitted as plain scalars (`0.2`, `true`) so they
    # re-read with their native YAML types; `cast` converts them back anyway.
    # Strings and enums are force-quoted: an unquoted value like `yes`, `no`,
    # `null` or `123` would otherwise be re-parsed by YAML 1.1 as a bool / nil
    # / int and corrupt the value on reload. `stringify` already normalizes
    # `Time::Span` to seconds.
    def emit_yaml(yaml : YAML::Builder) : Nil
      {% if T == Bool || T == Int32 || T == Int64 || T == Float64 || T == Time::Span %}
        yaml.scalar stringify
      {% else %}
        yaml.scalar stringify, style: YAML::ScalarStyle::DOUBLE_QUOTED
      {% end %}
    end

    def emit_json(json : JSON::Builder) : Nil
      v = @value
      {% if T == Bool || T == Int32 || T == Int64 || T == Float64 %}
        v.to_json json
      {% elsif T == Time::Span %}
        normalize(v.total_seconds).to_json json
      {% else %}
        stringify.to_json json
      {% end %}
    end

    # ---- type <-> string conversions -------------------------------------

    # Parse a string into `T`. A `parse:` proc, if given, takes precedence;
    # otherwise built-in handling covers the common scalar and enum types.
    private def cast(str : String) : T
      if p = @parse
        return p.call(str)
      end
      {% if T == Bool %}
        {"1", "true", "yes", "on", "y"}.includes? str.strip.downcase
      {% elsif T == Int32 %}
        str.strip.to_i
      {% elsif T == Int64 %}
        str.strip.to_i64
      {% elsif T == Float64 %}
        str.strip.to_f
      {% elsif T == String %}
        str
      {% elsif T == Char %}
        raise ArgumentError.new("expected a single character") if str.empty?
        str[0]
      {% elsif T == Time::Span %}
        str.strip.to_f.seconds
      {% elsif T < Enum %}
        {% if T.annotation(Flags) %}
          r = T::None
          str.split(/[,|]/).each do |part|
            part = part.strip
            r |= T.parse(part) unless part.empty?
          end
          r
        {% else %}
          T.parse str.strip
        {% end %}
      {% else %}
        # No built-in parser for this type. A `parse:` proc would have been
        # used above; reaching here means none was supplied.
        raise "Superconf: no built-in parser for #{self.class}; pass a `parse:` proc to `register`"
      {% end %}
    end

    private def render(v : T) : String
      {% if T == Time::Span %}
        normalize(v.total_seconds).to_s
      {% else %}
        v.to_s
      {% end %}
    end

    # Render a seconds value without a needless trailing ".0" for whole
    # numbers (so `1.second` dumps as `1`, not `1.0`).
    private def normalize(seconds : Float64)
      seconds == seconds.to_i64 ? seconds.to_i64 : seconds
    end
  end
end
