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

    # The option an *alias* forwards to, or `nil` for a normal option. An alias
    # (see `Superconf.register_alias`) is an extra name that shares another
    # option's value, type, default, parsing and validation.
    def alias_target : AbstractOption?
      nil
    end

    # Build an alias of this option, registered under *key* with its own
    # env/CLI/group surfaces but sharing this option's value. Used by
    # `Superconf.register_alias`.
    abstract def build_alias(key : String, *, explicit_env : String?,
                             cli : String, group : String,
                             description : String) : AbstractOption

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
    # precedence so config/env/CLI/runtime still win. The new default is itself
    # validated: `set` at `Default` precedence is skipped when a higher source
    # already won, so without this an invalid default could be recorded behind
    # the override and later surface (e.g. via `default_string`, or if the
    # higher source is cleared).
    def default=(value : T)
      check_default value
      @default = value
    end

    def initialize(key : String, @default : T, *, explicit_env : String?, cli : String,
                   group : String, description : String,
                   @parse : Proc(String, T)? = nil,
                   @validate : Proc(T, Bool)? = nil)
      @value = @default
      super(key, explicit_env, cli, group, description)
      # Catch a bad default at declaration time, not on first use.
      check_default @default
    end

    # Raise unless *value* passes the option's `validate` predicate (if any).
    # Guards the recorded default so it always satisfies validation, regardless
    # of the effective value's precedence.
    private def check_default(value : T) : Nil
      if v = @validate
        raise Error.new("default value #{value.inspect} fails validation for option #{key.inspect}") unless v.call(value)
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
      {% if T == Float64 %}
        # A non-finite Float64 (reachable: `cast` accepts "inf"/"nan" via
        # `String#to_f`) has no plain decimal form. Emitting `Infinity`/`NaN`
        # would re-read as a *string*, not a float — breaking the "native YAML
        # types" promise above (mirrors the JSON path, which can't even emit one
        # natively). YAML's special-float spellings `.inf`/`-.inf`/`.nan` re-read
        # as native floats. Finite floats keep their plain scalar form.
        v = @value
        yaml.scalar(v.finite? ? stringify : (v.nan? ? ".nan" : (v > 0 ? ".inf" : "-.inf")))
      {% elsif T == Bool || T == Int32 || T == Int64 || T == Time::Span %}
        yaml.scalar stringify
      {% else %}
        yaml.scalar stringify, style: YAML::ScalarStyle::DOUBLE_QUOTED
      {% end %}
    end

    def emit_json(json : JSON::Builder) : Nil
      v = @value
      {% if T == Bool || T == Int32 || T == Int64 %}
        v.to_json json
      {% elsif T == Float64 %}
        # JSON has no literal for a non-finite float, and `Float64#to_json` raises
        # on `Infinity`/`-Infinity`/`NaN` — which would abort the whole dump (such
        # a value is reachable: `cast` accepts "inf"/"nan" via `String#to_f`). Emit
        # it as a string so the document stays valid; it still re-loads, since
        # `String#to_f` parses those words back to the same value. Finite floats
        # keep emitting as native JSON numbers.
        v.finite? ? v.to_json(json) : v.to_s.to_json(json)
      {% elsif T == Time::Span %}
        normalize(v.total_seconds).to_json json
      {% else %}
        stringify.to_json json
      {% end %}
    end

    def build_alias(key : String, *, explicit_env : String?, cli : String,
                    group : String, description : String) : AbstractOption
      Alias(T).new(key, self, explicit_env: explicit_env, cli: cli,
        group: group, description: description)
    end

    # ---- type <-> string conversions -------------------------------------

    # Parse a string into `T`. A `parse:` proc, if given, takes precedence;
    # otherwise built-in handling covers the common scalar and enum types.
    private def cast(str : String) : T
      if p = @parse
        return p.call(str)
      end
      {% if T == Bool %}
        # Recognize an explicit truthy/falsey vocabulary and reject anything
        # else: like every other built-in type, an unparseable value (e.g. a
        # typo'd `ture`) must raise rather than silently collapse to `false`.
        case str.strip.downcase
        when "1", "true", "yes", "on", "y"
          true
        when "0", "false", "no", "off", "n"
          false
        else
          raise ArgumentError.new("expected a boolean (true/false, yes/no, on/off, 1/0)")
        end
      {% elsif T == Int32 %}
        # `prefix: true` also accepts `0x`/`0o`/`0b` (hex/octal/binary) and a
        # leading sign before the prefix (e.g. `-0x1F`); a plain decimal string
        # still parses as base 10 (a bare leading `0` is NOT treated as octal).
        str.strip.to_i prefix: true
      {% elsif T == Int64 %}
        str.strip.to_i64 prefix: true
      {% elsif T == Float64 %}
        str.strip.to_f
      {% elsif T == String %}
        str
      {% elsif T == Char %}
        # A `Char` is exactly one Unicode codepoint, so a multi-codepoint
        # grapheme cluster (e.g. a flag emoji) genuinely can't be stored here —
        # reject it rather than silently truncate to its first codepoint.
        raise ArgumentError.new("expected a single character (one codepoint)") unless str.size == 1
        str[0]
      {% elsif T == Time::Span %}
        parse_time_span str
      {% elsif T < Enum %}
        {% if T.annotation(Flags) %}
          # Reject input with no recognizable flag (empty, or only separators /
          # whitespace): like every other built-in type, garbage must raise
          # rather than silently collapse — here to `None`. An explicit `None`
          # is still accepted, since it is a real, non-empty token that parses.
          parts = str.split(/[,|]/).map(&.strip).reject(&.empty?)
          raise ArgumentError.new("expected one or more flags (comma- or pipe-separated)") if parts.empty?
          r = T::None
          parts.each { |part| r |= T.parse(part) }
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

    # Parse a duration string into a `Time::Span`. The numeric part may carry an
    # optional unit suffix: `ms` (milliseconds), `s` (seconds), `m` (minutes),
    # `h` (hours) or `d` (days). A bare number with NO suffix means seconds, so
    # existing configs keep their meaning. Suffixes are case-insensitive and may
    # be separated from the number by whitespace.
    private def parse_time_span(str : String) : Time::Span
      s = str.strip
      m = s.match(/\A([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)\s*([a-zA-Z]*)\z/)
      raise ArgumentError.new(%(expected a duration like "500ms", "2m", "1.5h" or a bare number of seconds)) unless m
      num = m[1].to_f
      case m[2].downcase
      when "", "s" then num.seconds
      when "ms"    then num.milliseconds
      when "m"     then num.minutes
      when "h"     then num.hours
      when "d"     then num.days
      else
        raise ArgumentError.new("unknown time unit #{m[2].inspect} (use ms, s, m, h, d)")
      end
    end

    private def render(v : T) : String
      {% if T == Time::Span %}
        normalize(v.total_seconds).to_s
      {% else %}
        v.to_s
      {% end %}
    end

    # Render a seconds value without a needless trailing ".0" for whole
    # numbers (so `1.second` dumps as `1`, not `1.0`). A value outside `Int64`'s
    # range (e.g. `Time::Span::MAX`, whose `total_seconds` rounds up to 2**63) —
    # or a non-finite one — is left as a `Float64`: `to_i64` would otherwise
    # raise `OverflowError` and crash every dump/`stringify` path. `2**63` (one
    # past `Int64::MAX`) is the exact threshold, since `Int64::MAX.to_f` rounds
    # up to it.
    private def normalize(seconds : Float64)
      if seconds.finite? && seconds.abs < 9223372036854775808.0 && seconds == seconds.to_i64
        seconds.to_i64
      else
        seconds
      end
    end
  end

  # An *alias*: a second name for an already-registered option, sharing its one
  # value, type, default, parsing and validation. It carries its own config key,
  # environment variable and CLI flag, but every read and write forwards to the
  # target option, so the two names are always in sync.
  #
  # Created by `Superconf.register_alias` / `Superconf.option_alias` when an app
  # wants to *promote* a lower-level (library) option under its own name. The
  # target is always a concrete `Option(T)`: aliases of aliases collapse to the
  # underlying option (see `Superconf.register_alias`), so there is never a chain
  # to walk at read time.
  class Alias(T) < AbstractOption
    # The option this alias forwards to.
    getter target : Option(T)

    def initialize(key : String, @target : Option(T), *, explicit_env : String?,
                   cli : String, group : String, description : String)
      super(key, explicit_env, cli, group, description)
    end

    def alias_target : AbstractOption
      @target
    end

    # The shared value, read straight from the target.
    def value : T
      @target.value
    end

    # Assign through to the target option (same precedence rules apply).
    def set(value : T, source : Source = Source::Runtime, origin : String = "API") : Nil
      @target.set value, source, origin
    end

    # `source`/`origin` mirror the target's, so a dump shows where the shared
    # value actually came from regardless of which name set it.
    def source : Source
      @target.source
    end

    def origin : String
      @target.origin
    end

    def stringify : String
      @target.stringify
    end

    def default_string : String
      @target.default_string
    end

    def set_from_string(str : String, source : Source, origin : String) : Nil
      @target.set_from_string str, source, origin
    end

    def bool? : Bool
      @target.bool?
    end

    def emit_yaml(yaml : YAML::Builder) : Nil
      @target.emit_yaml yaml
    end

    def emit_json(json : JSON::Builder) : Nil
      @target.emit_json json
    end

    # Aliasing an alias targets the same underlying option, never this wrapper.
    def build_alias(key : String, *, explicit_env : String?, cli : String,
                    group : String, description : String) : AbstractOption
      @target.build_alias key, explicit_env: explicit_env, cli: cli,
        group: group, description: description
    end
  end
end
