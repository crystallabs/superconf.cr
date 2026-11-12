require "json"
require "yaml"

# Superconf — a small, framework-agnostic, process-wide configuration registry.
#
# Every tunable is registered once with `Superconf.option` (or `.register`),
# then reachable from four surfaces kept in sync automatically:
#
# * a **config key**, e.g. `screen.resize_interval`
# * an **environment variable**, derived as `<PREFIX>SCREEN_RESIZE_INTERVAL`
# * a **command-line option**, derived as `--screen-resize-interval`
# * the **runtime value**, via a typed accessor (`Superconf.screen_resize_interval`)
#   or `Superconf.get`
#
# Each effective value also carries a `Source` and a human-readable `origin`.
#
# The registry is a single process-wide singleton, so independent components
# (e.g. a terminal library and the app using it) appear together in one
# combined, dumpable list.
module Superconf
  # Raised for any configuration error: unknown key, type mismatch, or
  # unparseable value. Rescue this one type to handle all malformed-config cases.
  class Error < Exception
  end

  # Where an option's current value came from. Ordered by precedence: a higher
  # member overrides a lower one (command-line > env > config file > default);
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
    # Explicit env-var name, or `nil` to derive one lazily from the registry
    # prefix + key (see `Superconf.env_name`). Lazy so the prefix can be set
    # after options are registered (e.g. by the app, across libraries).
    getter explicit_env : String?
    getter cli : String
    getter group : String
    getter description : String
    getter source : Source = Source::Default
    getter origin : String = "default"

    def initialize(@key, @explicit_env, @cli, @group, @description)
    end

    # The blocks `#on_change` registered, called after every change of the
    # value (not of its source alone).
    @listeners = [] of Proc(Nil)

    # Registers *block* to run whenever the option's value changes — from a
    # config file, an env var, the command line, a runtime assignment or a
    # `reset` — so a value read into a UI control, a cache or a derived
    # setting can follow it. Not called for an assignment that leaves the
    # value as it was (one a higher-precedence source outranked, or one equal
    # to the current value). Returns the block, the handle `#off_change`
    # takes.
    #
    # ```
    # Superconf["app.theme"].on_change { apply_theme Superconf.app_theme }
    # ```
    def on_change(&block : ->) : Proc(Nil)
      @listeners << block
      block
    end

    # Unregisters a *block* `#on_change` returned. Returns whether it was
    # registered.
    def off_change(block : Proc(Nil)) : Bool
      !@listeners.delete(block).nil?
    end

    # Runs the `#on_change` blocks; called by the typed option after its
    # value changed. Over a snapshot of the list, so a block may `off_change`
    # itself (a one-shot) or register another without the walk skipping or
    # repeating one; a change is rare enough for the copy not to matter.
    protected def notify_change : Nil
      return if @listeners.empty?
      @listeners.dup.each &.call
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
    # (see `Superconf.register_alias`) shares another option's value, type,
    # default, parsing and validation.
    def alias_target : AbstractOption?
      nil
    end

    # Build an alias of this option, registered under *key* with its own
    # env/CLI/group surfaces but sharing this option's value. Used by
    # `Superconf.register_alias`.
    abstract def build_alias(key : String, *, explicit_env : String?,
                             cli : String, group : String,
                             description : String) : AbstractOption

    # Puts the option back to its registered default (see `Superconf.reset`).
    abstract def reset : Nil

    # :nodoc:
    # Typed assignment of a value whose static type is only known at the
    # call site (`Superconf.set`): applied when *value* is one the option's
    # type holds — a `String` or `nil` for a `String?` option — and answered
    # with whether it was.
    abstract def try_set(value, source : Source, origin : String) : Bool

    # :nodoc:
    # `Superconf.set_default`'s counterpart of `try_set`.
    abstract def try_set_default(value) : Bool

    # Key with its leading `<group>.` stripped, for grouped dumps. A key
    # without a dot is returned unchanged.
    def leaf_key : String
      key.includes?('.') ? key.split('.', 2)[1] : key
    end

    # Whether the option still carries its registered default. Compared as the
    # rendered string so it works uniformly for any option type; a value set
    # equal to the default counts as "at default". The question by source
    # ("did anything set this?") is `Superconf.configured?`.
    def at_default? : Bool
      stringify == default_string
    end
  end

  # :nodoc:
  # Writes *str* as a JSON string a YAML reader takes back unchanged — the
  # loaders read `.json` with the YAML parser. `JSON::Builder` leaves DEL,
  # the C1 controls (NEL among them), U+2028/U+2029, the BOM and the
  # non-characters raw, which YAML folds into a space or refuses outright;
  # they are written as `\uXXXX` escapes instead.
  def self.json_string(json : JSON::Builder, str : String) : Nil
    if str.each_char.any? { |c| yaml_unsafe?(c) }
      escaped = str.to_json.gsub { |c| yaml_unsafe?(c) ? "\\u%04x" % c.ord : c }
      json.raw escaped
    else
      json.string str
    end
  end

  private def self.yaml_unsafe?(c : Char) : Bool
    o = c.ord
    (0x7f <= o <= 0x9f) || o == 0x2028 || o == 0x2029 || o == 0xfeff || o == 0xfffe || o == 0xffff
  end

  # One registered, typed configuration option.
  #
  # `T` may be `Bool`, any primitive integer or float type (`Int32`, `UInt8`,
  # `Float64`, ...), `String`, `Char`, `Time::Span`, or any `Enum` (including
  # `@[Flags]` enums). Any other type is supported by passing an explicit
  # `parse:` proc to `register`.
  class Option(T) < AbstractOption
    getter default : T
    getter value : T

    # Change the recorded default (used by `Superconf.set_default`). Doesn't
    # itself change the effective `value`; the caller also `set`s at `Default`
    # precedence so config/env/CLI/runtime still win. Validated here because a
    # `set` at `Default` precedence is skipped once a higher source has won, so
    # an invalid default could otherwise slip in unvalidated and later surface
    # (e.g. via `default_string`, or once the higher source is cleared).
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
    # Guards the recorded default so it satisfies validation regardless of the
    # effective value's precedence.
    private def check_default(value : T) : Nil
      validate!(value) { "default value #{value.inspect} fails validation for option #{key.inspect}" }
    end

    # Shared validation core for default-time and assignment-time checks: raises
    # `Error` unless *value* passes `validate` (no-op if none set). Message is
    # built lazily by the block, so interpolation cost is paid only on failure.
    private def validate!(value : T, & : -> String) : Nil
      if v = @validate
        raise Error.new(yield) unless v.call(value)
      end
    end

    # Typed assignment. Applies only if *source* is at least as authoritative
    # as the source of the current value (see `Source`); a value that wins
    # must also pass the option's `validate` predicate, if any.
    def set(value : T, source : Source = Source::Runtime, origin : String = "API") : Nil
      return if source < @source
      validate!(value) { "invalid value #{value.inspect} for option #{@key} (#{origin})" }
      assign value, source, origin
    end

    # :nodoc:
    def try_set(value, source : Source, origin : String) : Bool
      return false unless value.is_a?(T)
      set value, source, origin
      true
    end

    # :nodoc:
    def try_set_default(value) : Bool
      return false unless value.is_a?(T)
      # Validate first; record the new default only after it succeeds, so a
      # value that fails the validator doesn't leave an invalid default behind.
      set value, Source::Default, "default (set by app)"
      self.default = value
      true
    end

    # A `nil` value and an empty string render alike, but are not the same
    # setting: a `String?` option set to "" is not at a `nil` default.
    def at_default? : Bool
      return false if @value.nil? != @default.nil?
      super
    end

    # Puts the option back to its registered default, at `Source::Default`
    # precedence, as if nothing had ever configured it (see
    # `Superconf.reset`).
    def reset : Nil
      assign @default, Source::Default, "default"
    end

    # Records *value* as coming from *source*, and tells the `on_change`
    # blocks when it differs from the value before.
    private def assign(value : T, source : Source, origin : String) : Nil
      # NaN is unequal to itself; assigning it again is still no change.
      changed = {% if T < Float::Primitive %}
                  !(@value == value || (@value.nan? && value.nan?))
                {% else %}
                  @value != value
                {% end %}
      @value = value
      @source = source
      @origin = origin
      notify_change if changed
    end

    def set_from_string(str : String, source : Source, origin : String) : Nil
      # Skip values a higher-precedence source already set: don't parse or
      # validate something we'd discard anyway (so a bad value in a file
      # overridden by a CLI flag never trips an error).
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
    # re-read with their native YAML types. Strings and enums are force-quoted:
    # an unquoted `yes`, `no`, `null` or `123` would otherwise be re-parsed by
    # YAML 1.1 as a bool/nil/int and corrupt the value on reload. `stringify`
    # already normalizes `Time::Span` to seconds.
    def emit_yaml(yaml : YAML::Builder) : Nil
      {% if T < Float::Primitive %}
        # A non-finite float (reachable via `cast`'s "inf"/"nan" parsing) has no
        # plain decimal form. Emitting `Infinity`/`NaN` would re-read as a string,
        # not a float. YAML's special spellings `.inf`/`-.inf`/`.nan` re-read as
        # native floats; finite floats keep their plain scalar form.
        v = @value
        yaml.scalar(v.finite? ? stringify : (v.nan? ? ".nan" : (v > 0 ? ".inf" : "-.inf")))
      {% elsif T < Int::Primitive %}
        yaml.scalar stringify, style: (int64_range? ? YAML::ScalarStyle::ANY : YAML::ScalarStyle::DOUBLE_QUOTED)
      {% elsif T == Bool || T == Time::Span %}
        yaml.scalar stringify
      {% else %}
        # A `nil` (a `String?` option) is a YAML null, which the loaders take
        # as unset — not "", which would reload as an empty string.
        if @value.nil?
          yaml.scalar "~"
        else
          yaml.scalar stringify, style: YAML::ScalarStyle::DOUBLE_QUOTED
        end
      {% end %}
    end

    def emit_json(json : JSON::Builder) : Nil
      v = @value
      {% if T == Bool %}
        v.to_json json
      {% elsif T < Int::Primitive %}
        int64_range? ? v.to_json(json) : json.string(stringify)
      {% elsif T < Float::Primitive %}
        # JSON has no literal for a non-finite float; `Float#to_json` raises on
        # `Infinity`/`-Infinity`/`NaN` (reachable via `cast`'s "inf"/"nan"
        # parsing), which would abort the dump. Emit as a string instead — still
        # re-loads since `String#to_f` parses those words back. Finite floats
        # emit as native JSON numbers.
        v.finite? ? v.to_json(json) : json.string(v.to_s)
      {% elsif T == Time::Span %}
        # The exact decimal `render` writes is a JSON number as it stands.
        json.raw stringify
      {% else %}
        if v.nil?
          json.null
        else
          Superconf.json_string json, stringify
        end
      {% end %}
    end

    # Whether an integer value fits a YAML or JSON reader's native integer,
    # an `Int64` (in Crystal's readers, this library's loaders included). A
    # value beyond that range — a large `UInt64`, an `Int128` — emitted as a
    # plain number would re-read as a float, or not at all; quoted, it
    # re-reads as its digits, which `cast` parses.
    private def int64_range? : Bool
      {% if T < Int::Primitive %}
        Int64::MIN <= @value <= Int64::MAX
      {% else %}
        true
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
        # Recognize an explicit truthy/falsey vocabulary; reject anything else
        # (e.g. a typo'd `ture`) rather than silently collapsing to `false`.
        case str.strip.downcase
        when "1", "true", "yes", "on", "y"
          true
        when "0", "false", "no", "off", "n"
          false
        else
          raise ArgumentError.new("expected a boolean (true/false, yes/no, on/off, 1/0)")
        end
      {% elsif T < Int::Primitive %}
        # `prefix: true` also accepts `0x`/`0o`/`0b` and a leading sign before the
        # prefix (e.g. `-0x1F`); a bare leading `0` is not treated as octal.
        # `underscore: true` takes the digit grouping YAML allows (`1_000`).
        T.new str.strip, prefix: true, underscore: true
      {% elsif T < Float::Primitive %}
        # YAML's spellings of the non-finite values, which the YAML dump
        # writes, besides the `inf`/`nan` words `String#to_f` reads.
        case s = str.strip.downcase
        when ".inf", "+.inf" then T::INFINITY
        when "-.inf"         then -T::INFINITY
        when ".nan"          then T::NAN
        else                      T.new s
        end
      {% elsif T == String %}
        str
      {% elsif T == Char %}
        # A `Char` is exactly one codepoint, so a multi-codepoint grapheme
        # cluster (e.g. a flag emoji) can't be stored — reject rather than
        # silently truncate.
        raise ArgumentError.new("expected a single character (one codepoint)") unless str.size == 1
        str[0]
      {% elsif T == Time::Span %}
        parse_time_span str
      {% elsif T < Enum %}
        {% if T.annotation(Flags) %}
          # Reject input with no recognizable flag (empty, or only separators/
          # whitespace) rather than silently collapsing to `None`. An explicit
          # `None` token is still accepted.
          parts = str.split(/[,|]/).map(&.strip).reject(&.empty?)
          raise ArgumentError.new("expected one or more flags (comma- or pipe-separated)") if parts.empty?
          r = T::None
          parts.each { |part| r |= T.parse(part) }
          r
        {% else %}
          T.parse str.strip
        {% end %}
      {% else %}
        # No built-in parser for this type and no `parse:` proc was supplied.
        raise "Superconf: no built-in parser for #{self.class}; pass a `parse:` proc to `register`"
      {% end %}
    end

    # Parse a duration string into a `Time::Span`. Optional unit suffix: `ms`,
    # `s`, `m`, `h`, `d`. A bare number with no suffix means seconds. Suffixes
    # are case-insensitive and may be separated from the number by whitespace.
    private def parse_time_span(str : String) : Time::Span
      s = str.strip
      m = s.match(/\A([+-]?)(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?\s*([a-zA-Z]*)\z/)
      raise ArgumentError.new(%(expected a duration like "500ms", "2m", "1.5h" or a bare number of seconds)) unless m
      unit_ns = case m[4].downcase
                when "", "s" then 1_000_000_000_i64
                when "ms"    then 1_000_000_i64
                when "m"     then 60_000_000_000_i64
                when "h"     then 3_600_000_000_000_i64
                when "d"     then 86_400_000_000_000_i64
                else
                  raise ArgumentError.new("unknown time unit #{m[4].inspect} (use ms, s, m, h, d)")
                end
      whole, _, frac = m[2].partition('.')
      # An exponent, or more digits than the integer arithmetic below holds,
      # goes through a float; anything else is exact to the nanosecond, so
      # that a dumped span (see `render`) reloads as the same span.
      if m[3]? || whole.size > 19
        return ("#{m[1]}#{m[2]}#{m[3]?}".to_f * unit_ns).nanoseconds
      end
      frac = frac[0, 18]
      scale = 10_i128 ** frac.size
      ns = (whole.empty? ? 0_i128 : whole.to_i128) * unit_ns
      ns += (frac.to_i128 * unit_ns + scale // 2) // scale unless frac.empty?
      ns = -ns if m[1] == "-"
      Time::Span.new(seconds: ns.tdiv(1_000_000_000).to_i64, nanoseconds: ns.remainder(1_000_000_000).to_i32)
    end

    private def render(v : T) : String
      {% if T == Time::Span %}
        # Seconds as an exact decimal, from the span's integer parts rather
        # than `total_seconds` (a `Float64`, which drops nanoseconds from a
        # long span and overflows on reload at `Time::Span::MAX`); no
        # fraction for whole seconds, so `1.second` dumps as `1`.
        secs = v.to_i.to_i128
        nanos = v.nanoseconds
        String.build do |io|
          io << '-' if secs < 0 || nanos < 0
          io << secs.abs
          if nanos != 0
            io << '.' << nanos.abs.to_s.rjust(9, '0').rstrip('0')
          end
        end
      {% else %}
        v.to_s
      {% end %}
    end
  end

  # A second name for an already-registered option, sharing its value, type,
  # default, parsing and validation. Carries its own config key, environment
  # variable and CLI flag, but every read/write forwards to the target option.
  #
  # Created by `Superconf.register_alias` / `.option_alias` to promote a
  # lower-level (library) option under an app's own name. The target is always
  # a concrete `Option(T)`: aliases of aliases collapse to the underlying
  # option (see `Superconf.register_alias`), so there's never a chain to walk.
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

    # :nodoc:
    def try_set(value, source : Source, origin : String) : Bool
      @target.try_set value, source, origin
    end

    # :nodoc:
    def try_set_default(value) : Bool
      @target.try_set_default value
    end

    # Resets the shared value (see `Option#reset`).
    def reset : Nil
      @target.reset
    end

    # Watches the shared value: the block is registered on the target, so a
    # change through either name reaches it.
    def on_change(&block : ->) : Proc(Nil)
      @target.on_change(&block)
    end

    # :ditto:
    def off_change(block : Proc(Nil)) : Bool
      @target.off_change block
    end

    # Mirrors the target's, so a dump shows where the shared value actually
    # came from regardless of which name set it.
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
