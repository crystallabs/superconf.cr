require "./spec_helper"

# A @[Flags] enum to exercise enum / flags parsing.
@[Flags]
enum SCFlags
  A
  B
  C
end

# Options declared via the `option` macro (typed accessors). `regtest_eager`'s
# accessor is intentionally never called, to prove eager registration.
module Superconf
  option "app.threads", 4, description: "app-defined option"
  option "regtest.eager", 123, description: "eager-registration regression"

  # A library option the app promotes under its own typed name.
  option "lib.resize_interval", 0.2.seconds, description: "library option"
  option_alias "myapp.refresh", "lib.resize_interval", Time::Span
end

describe Superconf do
  describe "registration & derivation" do
    it "derives env (prefix + key), CLI flag and group" do
      opt = Superconf.register "t1.resize_interval", 0.2.seconds
      Superconf.env_name(opt).should eq "T1_RESIZE_INTERVAL" # default prefix is ""
      opt.cli.should eq "--t1-resize-interval"
      opt.group.should eq "t1"
      opt.value.should eq 0.2.seconds
      opt.source.should eq Superconf::Source::Default
    end

    it "applies env_prefix lazily, even to already-registered options" do
      opt = Superconf.register "t1b.x", 1
      Superconf.env_prefix = "PFX_"
      Superconf.env_name(opt).should eq "PFX_T1B_X"
    ensure
      Superconf.env_prefix = ""
    end

    it "supports typed get/set" do
      Superconf.register "t2.count", 3
      Superconf.get("t2.count", Int32).should eq 3
      Superconf.set "t2.count", 9
      Superconf.get("t2.count", Int32).should eq 9
      Superconf["t2.count"].source.should eq Superconf::Source::Runtime
    end

    it "raises on duplicate keys" do
      Superconf.register "t3.x", true
      expect_raises(ArgumentError, /already registered/) do
        Superconf.register "t3.x", false
      end
    end

    it "rejects two distinct keys that derive the same CLI flag" do
      # `.` and `_` both map to `-` in a derived CLI flag, so distinct keys can
      # collide on one flag (here both yield `--t3b-log-level`). `load_args` keys
      # its OptionParser handlers by flag string, so without this guard the
      # second registration silently shadows the first on the command line (while
      # env/config, named independently, would still set both).
      Superconf.register "t3b.log.level", 0
      expect_raises(ArgumentError, /CLI flag .* already used/) do
        Superconf.register "t3b.log_level", 0
      end
    end

    it "rejects two options claiming the same explicit env var" do
      # Two options sharing one environment variable can't be set independently
      # (`load_env` reads the single var into both), and `dump_env` emits two
      # `export`s for it, so sourcing then reloading the env dump silently
      # collapses both to one value. Reject the clash, like a duplicate CLI flag.
      # The distinct keys here derive distinct CLI flags, so only the explicit
      # `env:` collides.
      Superconf.register "t3d.first", 0, env: "T3D_SHARED"
      expect_raises(ArgumentError, /environment variable .* already used/) do
        Superconf.register "t3d.second", 0, env: "T3D_SHARED"
      end
    end

    it "rejects two derived env vars that collide only by letter case" do
      # `env_name` upper-cases the key while `derive_cli` preserves case, so two
      # keys differing only in letter case derive the *same* env var (`ENVCASE_
      # FOO`) but *different* CLI flags (`--envcase-foo` vs `--envcasE-foo`). The
      # CLI guard therefore cannot catch this; without a dedicated derived-env
      # guard, `load_env` would read the one variable into both options and
      # `dump_env` would emit two identical `export` lines, collapsing both to one
      # value on reload — the very breakage the explicit-env guard prevents.
      a = Superconf.register "envcase.foo", 1
      Superconf.env_name(a).should eq "ENVCASE_FOO"
      expect_raises(ArgumentError, /environment variable .* already used/) do
        Superconf.register "envcasE.foo", 2 # same derived env, different CLI flag
      end
      # An explicit `env:` is the documented escape hatch and registers cleanly.
      b = Superconf.register "envcasE.foo", 2, env: "ENVCASE_FOO_2"
      Superconf.env_name(b).should eq "ENVCASE_FOO_2"
    end

    it "rejects an option claiming a CLI flag reserved by load_args" do
      # `load_args` always registers `--config` and `--dump-config` itself.
      # An option deriving (here, key `config`) or given one of those flags
      # would be registered first and then silently overwritten by the built-in
      # handler (OptionParser keys handlers by flag string), leaving the option
      # unreachable from the command line. Reject it up front.
      expect_raises(ArgumentError, /reserved/) do
        Superconf.register "config", "x"
      end
      expect_raises(ArgumentError, /reserved/) do
        Superconf.register "t3c.dump", 0, cli: "--dump-config"
      end
    end

    it "treats an empty explicit env:/cli: override as no override (derives instead)" do
      # A blank `env:`/`cli:` must fold into the derived name, not become the
      # option's actual env-var name / flag. An empty env name is unusable:
      # `ENV[""]` is never set (so `load_env` can't reach the option) and
      # `dump_env` would emit the invalid line `export ='value'`. An empty cli is
      # an unusable, valueless flag. Empty == "not provided", like `nil`.
      o = Superconf.register "t3e.port", 80, env: "", cli: ""
      o.explicit_env.should be_nil
      Superconf.env_name(o).should eq "T3E_PORT" # derived, not ""
      o.cli.should eq "--t3e-port"               # derived, not "=VALUE"

      # The derived surfaces actually work, and the env dump round-trips.
      ENV["T3E_PORT"] = "81"
      Superconf.load_env
      o.value.should eq 81
      String.build { |s| Superconf.dump s, Superconf::Format::Env }
        .should contain "export T3E_PORT='81'"
    ensure
      ENV.delete "T3E_PORT"
    end
  end

  describe "typed accessors (option macro)" do
    it "exposes options as typed methods" do
      Superconf.app_threads.should eq 4
      typeof(Superconf.app_threads).should eq Int32
      Superconf.app_threads = 8
      Superconf.app_threads.should eq 8
      Superconf["app.threads"].source.should eq Superconf::Source::Runtime
    ensure
      Superconf.app_threads = 4
    end

    it "registers eagerly regardless of use" do
      # `regtest_eager` accessor is never called; the option must still register.
      Superconf["regtest.eager"]?.should_not be_nil
    end
  end

  describe "precedence" do
    it "honors Default < ConfigFile < Env < CommandLine < Runtime" do
      o = Superconf.register "t4.v", 1
      o.set_from_string "2", Superconf::Source::ConfigFile, "file"
      o.value.should eq 2
      o.set_from_string "3", Superconf::Source::Env, "env"
      o.value.should eq 3
      o.set_from_string "99", Superconf::Source::ConfigFile, "file" # lower → ignored
      o.value.should eq 3
      o.set_from_string "4", Superconf::Source::CommandLine, "cli"
      o.value.should eq 4
      o.set 5
      o.value.should eq 5
    end
  end

  describe "type parsing" do
    it "parses bools, ints, floats, time spans and flag enums" do
      Superconf.register "t5.flag", false
      Superconf.register "t5.span", 1.second
      Superconf.register "t5.opt", SCFlags::None

      Superconf["t5.flag"].set_from_string "yes", Superconf::Source::Env, "e"
      Superconf.get("t5.flag", Bool).should be_true

      Superconf["t5.span"].set_from_string "0.5", Superconf::Source::Env, "e"
      Superconf.get("t5.span", Time::Span).should eq 0.5.seconds

      Superconf["t5.opt"].set_from_string "a,b", Superconf::Source::Env, "e"
      v = Superconf.get("t5.opt", SCFlags)
      v.a?.should be_true
      v.b?.should be_true
    end

    it "rejects an empty flags string instead of silently yielding None" do
      Superconf.register "t5c.opt", SCFlags::A
      expect_raises(Superconf::Error, /cannot parse ""/) do
        Superconf["t5c.opt"].set_from_string "", Superconf::Source::Env, "e"
      end
      # An explicit `None` is still a valid, non-empty token.
      Superconf["t5c.opt"].set_from_string "None", Superconf::Source::Env, "e"
      Superconf.get("t5c.opt", SCFlags).none?.should be_true
    end

    it "rejects an unrecognized boolean string" do
      Superconf.register "t5b.flag", false
      expect_raises(Superconf::Error, /cannot parse "ture"/) do
        Superconf["t5b.flag"].set_from_string "ture", Superconf::Source::Env, "e"
      end
    end

    it "parses a Char option (single character)" do
      Superconf.register "t14.glyph", '▮'
      Superconf["t14.glyph"].set_from_string "x", Superconf::Source::Env, "e"
      Superconf.get("t14.glyph", Char).should eq 'x'
    end

    it "rejects a multi-character string for a Char option" do
      Superconf.register "t14b.glyph", '▮'
      expect_raises(Superconf::Error, /cannot parse "abc"/) do
        Superconf["t14b.glyph"].set_from_string "abc", Superconf::Source::Env, "e"
      end
    end

    it "parses Time::Span unit suffixes (and bare seconds stays seconds)" do
      Superconf.register "t5d.span", 1.second

      # Backward compatibility: a bare number still means seconds.
      Superconf["t5d.span"].set_from_string "0.5", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 0.5.seconds

      Superconf["t5d.span"].set_from_string "500ms", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 500.milliseconds

      Superconf["t5d.span"].set_from_string "2m", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 2.minutes

      Superconf["t5d.span"].set_from_string "1h", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 1.hour

      Superconf["t5d.span"].set_from_string "1d", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 1.day

      # Case-insensitive and tolerant of whitespace before the unit.
      Superconf["t5d.span"].set_from_string "1.5 H", Superconf::Source::Runtime, "r"
      Superconf.get("t5d.span", Time::Span).should eq 1.5.hours
    end

    it "rejects an unparseable / unknown-unit Time::Span" do
      Superconf.register "t5e.span", 1.second
      expect_raises(Superconf::Error, /cannot parse "abc"/) do
        Superconf["t5e.span"].set_from_string "abc", Superconf::Source::Env, "e"
      end
      expect_raises(Superconf::Error, /unknown time unit/) do
        Superconf["t5e.span"].set_from_string "5fortnights", Superconf::Source::Env, "e"
      end
    end

    it "parses ints in hex/octal/binary as well as decimal" do
      Superconf.register "t5f.n32", 0
      Superconf.register "t5f.n64", 0_i64

      # Decimal still works (backward compatible).
      Superconf["t5f.n32"].set_from_string "42", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n32", Int32).should eq 42

      Superconf["t5f.n32"].set_from_string "0x1F", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n32", Int32).should eq 31

      Superconf["t5f.n32"].set_from_string "0o17", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n32", Int32).should eq 15

      Superconf["t5f.n32"].set_from_string "0b1010", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n32", Int32).should eq 10

      Superconf["t5f.n32"].set_from_string "-0x1F", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n32", Int32).should eq -31

      Superconf["t5f.n64"].set_from_string "0xFF", Superconf::Source::Runtime, "r"
      Superconf.get("t5f.n64", Int64).should eq 255_i64

      # Use the same (Runtime) source as the sets above so the value is not
      # skipped by the lower-precedence-source optimization and the parse runs.
      expect_raises(Superconf::Error, /cannot parse "nope"/) do
        Superconf["t5f.n32"].set_from_string "nope", Superconf::Source::Runtime, "r"
      end
    end

    it "uses a custom parse proc when provided" do
      Superconf.register "t6.point", {0, 0},
        parse: ->(s : String) {
          a = s.split(",").map(&.to_i)
          {a[0], a[1]}
        }
      Superconf["t6.point"].set_from_string "3,4", Superconf::Source::Env, "e"
      Superconf.get("t6.point", Tuple(Int32, Int32)).should eq({3, 4})
    end
  end

  describe "validation" do
    it "accepts values that pass and rejects values that fail" do
      Superconf.register "v1.n", 10, validate: ->(n : Int32) { n > 0 }
      Superconf.set "v1.n", 5
      Superconf.get("v1.n", Int32).should eq 5
      expect_raises(Superconf::Error, /invalid value 0 for option v1.n/) do
        Superconf.set "v1.n", 0
      end
      Superconf.get("v1.n", Int32).should eq 5
    end

    it "rejects a default that fails its own validator" do
      expect_raises(Superconf::Error, /default value -1 fails validation/) do
        Superconf.register "v4.n", -1, validate: ->(n : Int32) { n > 0 }
      end
    end

    it "rejects an invalid new default even when outranked by a higher source" do
      Superconf.register "v5.n", 10, validate: ->(n : Int32) { n > 0 }
      Superconf.set "v5.n", 5 # Runtime outranks the Default set inside set_default
      expect_raises(Superconf::Error, /default value -1 fails validation/) do
        Superconf.set_default "v5.n", -1
      end
      Superconf.get("v5.n", Int32).should eq 5        # effective value untouched
      Superconf["v5.n"].default_string.should eq "10" # invalid default not recorded
    end
  end

  describe "error handling" do
    it "raises a contextual Error on an unparseable value" do
      Superconf.register "e1.n", 0
      ex = expect_raises(Superconf::Error) do
        Superconf["e1.n"].set_from_string "abc", Superconf::Source::Env, %(env E1_N="abc")
      end
      ex.message.not_nil!.should contain "e1.n"
      ex.message.not_nil!.should contain "abc"
    end

    it "raises Error for an unknown key and on a type mismatch" do
      expect_raises(Superconf::Error, /unknown config option/) { Superconf.get("e2.missing", Int32) }
      Superconf.register "e3.n", 1
      expect_raises(Superconf::Error, /not Option/) { Superconf.get("e3.n", String) }
    end
  end

  describe "loading" do
    it "applies env vars at Env precedence" do
      Superconf.register "t7.n", 0
      ENV["T7_N"] = "42"
      Superconf.load_env
      Superconf.get("t7.n", Int32).should eq 42
      Superconf["t7.n"].source.should eq Superconf::Source::Env
    ensure
      ENV.delete "T7_N"
    end

    it "treats a present-but-empty env var as unset, instead of crashing" do
      # A typed (non-String) option whose env var is set but empty (e.g.
      # `MYAPP_THREADS=`) must not force-parse "" into a crash that aborts the
      # whole `load_env`/`configure!` — an empty env var is the conventional
      # "not really set". This mirrors `load_args`'s handling of a value flag
      # given without its value.
      Superconf.register "t7b.n", 5
      ENV["T7B_N"] = ""
      Superconf.load_env                        # must not raise
      Superconf.get("t7b.n", Int32).should eq 5 # default, untouched
      Superconf["t7b.n"].source.should eq Superconf::Source::Default
    ensure
      ENV.delete "T7B_N"
    end

    it "sets a String option to \"\" from an empty env var, like --flag= and key: \"\"" do
      # The empty-value rule must be consistent across all three loaders: an
      # empty value is "unset" only for a typed (non-String) option. A *String*
      # option takes "" as a real value from the environment, exactly as it does
      # from `--flag=` (`load_args`) and `key: ""` (config). Previously `load_env`
      # skipped *all* empty env vars, so an empty `MYAPP_TITLE=` was silently
      # dropped instead of clearing a String option to "".
      Superconf.register "t7c.title", "orig"
      ENV["T7C_TITLE"] = ""
      Superconf.load_env
      Superconf.get("t7c.title", String).should eq "" # empty String is a real value
      Superconf["t7c.title"].source.should eq Superconf::Source::Env
    ensure
      ENV.delete "T7C_TITLE"
    end

    it "applies CLI flags at CommandLine precedence" do
      Superconf.register "t8.name", "a"
      Superconf.register "t8.on", false
      Superconf.load_args ["--t8-name=zebra", "--t8-on"], consume: false
      Superconf.get("t8.name", String).should eq "zebra"
      Superconf.get("t8.on", Bool).should be_true
    end

    it "turns on a bool with a short CLI flag (no broken --no- duplicate)" do
      # A bool registered with a short flag has no leading `--` to rewrite into a
      # negation, so the derived `--no-` would equal the flag itself. Registering
      # it twice must not overwrite the positive handler and make `-d` set false.
      Superconf.register "t8b.debug", false, cli: "-d"
      Superconf.load_args ["-d"], consume: false
      Superconf.get("t8b.debug", Bool).should be_true
    end

    it "does not let a bool's --no- negation clobber another option's explicit flag" do
      # `t8e.color` (default true, flag `--t8e-color`) derives the negation
      # `--no-t8e-color`, which is exactly the *primary* flag of `t8e.no_color`
      # (the real NO_COLOR convention). The derived negation must be suppressed so
      # `--no-t8e-color` reliably sets the explicit option rather than (depending
      # on registration order) flipping `t8e.color`.
      Superconf.register "t8e.color", true, cli: "--t8e-color"
      Superconf.register "t8e.no_color", false, cli: "--no-t8e-color"
      Superconf.load_args ["--no-t8e-color"], consume: false
      Superconf.get("t8e.no_color", Bool).should be_true
      Superconf.get("t8e.color", Bool).should be_true # untouched
    end

    it "ignores a recognized value flag given without its value, instead of crashing" do
      # A typed (non-String) option whose flag appears with no argument (a
      # trailing `--flag`) must not abort the program by parsing "" — the
      # no-op `missing_option` means such a flag is left untouched.
      Superconf.register "t8c.workers", 7
      Superconf.load_args ["--t8c-workers"], consume: false # no value follows
      Superconf.get("t8c.workers", Int32).should eq 7       # default, untouched
      Superconf["t8c.workers"].source.should eq Superconf::Source::Default

      # A normal value still applies, and an explicit empty string still sets a
      # String option (only the truly-missing case is skipped).
      Superconf.register "t8c.name", "orig"
      Superconf.load_args ["--t8c-name="], consume: false
      Superconf.get("t8c.name", String).should eq ""
    end

    it "ignores an explicit empty value (--flag=) for a typed option, instead of crashing" do
      # `--flag=` delivers a *present but empty* value, so `missing_option`
      # never fires — yet force-parsing "" into a non-String option still
      # crashes (e.g. `"".to_i`). It must be treated like an unset value (a
      # no-op), mirroring `load_env`'s empty-env handling, so one stray empty
      # CLI argument can't abort the whole parse.
      Superconf.register "t8d.workers", 7
      Superconf.load_args ["--t8d-workers="], consume: false # must not raise
      Superconf.get("t8d.workers", Int32).should eq 7        # default, untouched
      Superconf["t8d.workers"].source.should eq Superconf::Source::Default
    end

    it "loads nested and flat keys from YAML, ignoring unknowns" do
      Superconf.register "t9.alpha", 0
      Superconf.register "t9.beta", 0
      Superconf.load_yaml <<-YAML
        t9:
          alpha: 11
        t9.beta: 22
        stranger: 3
        YAML
      Superconf.get("t9.alpha", Int32).should eq 11
      Superconf.get("t9.beta", Int32).should eq 22
    end

    it "ignores a sequence value for a scalar key (no silent stringification)" do
      # A YAML/JSON sequence is not a scalar leaf. It must be ignored like a
      # mapping value for a scalar key — not fall through and get stored as the
      # array's Crystal inspect string (e.g. "[1, 2, 3]") into a String option.
      Superconf.register "t9b.title", "orig"
      Superconf.load_yaml "t9b.title: [1, 2, 3]"
      Superconf.get("t9b.title", String).should eq "orig" # untouched, no garbage
      Superconf["t9b.title"].source.should eq Superconf::Source::Default

      # A quoted scalar that merely *looks* like a list is a real scalar value
      # and still applies.
      Superconf.load_yaml %(t9b.title: "[1, 2, 3]")
      Superconf.get("t9b.title", String).should eq "[1, 2, 3]"
    end

    it "treats a present-but-empty config scalar as unset for a typed option, instead of crashing" do
      # `key: ""` for a non-String option (here Int) must be treated like an
      # unset value — a no-op — mirroring `load_env`/`load_args`, rather than
      # force-parsing "" into the type (`"".to_i`) and aborting the whole load
      # over one benign empty value (e.g. a templated config where a variable
      # expanded to nothing). A String option still takes "" as a real value.
      Superconf.register "t9c.n", 7
      Superconf.register "t9c.title", "orig"
      Superconf.load_yaml <<-YAML
        t9c.n: ""
        t9c.title: ""
        YAML
      Superconf.get("t9c.n", Int32).should eq 7 # untouched
      Superconf["t9c.n"].source.should eq Superconf::Source::Default
      Superconf.get("t9c.title", String).should eq "" # empty String is a real value
      Superconf["t9c.title"].source.should eq Superconf::Source::ConfigFile
    end

    it "wraps a missing config file in Superconf::Error" do
      # The class docs promise that rescuing `Superconf::Error` handles every
      # malformed-config case, a config file included — so an explicitly-named
      # file that does not exist must not leak a raw `File::NotFoundError`.
      expect_raises(Superconf::Error, /cannot read config file/) do
        Superconf.load_file "/nonexistent/superconf-spec-#{Process.pid}.yml"
      end
    end

    it "wraps a config path that is a directory in Superconf::Error" do
      # Reading a directory raises a plain `IO::Error` ("Is a directory"), not a
      # `File::Error` — pointing `--config` at a directory is a realistic mistake
      # and must still surface as `Superconf::Error`, not leak the raw IO error.
      expect_raises(Superconf::Error, /cannot read config file/) do
        Superconf.load_file Dir.tempdir
      end
    end

    it "wraps a malformed config document in Superconf::Error" do
      # The class docs promise that rescuing `Superconf::Error` handles every
      # malformed-config case, a config file included — so a syntactically
      # broken document must not leak a raw `YAML::ParseException`.
      Superconf.register "t10.n", 1
      expect_raises(Superconf::Error, /cannot parse config file/) do
        Superconf.load_yaml "t10:\n  n: 1\n :\n  - [", "config file bad.yml"
      end
    end
  end

  describe "dumping" do
    it "produces re-loadable YAML that round-trips" do
      Superconf.register "t11.a", 5
      Superconf.register "t11.b", true
      Superconf.set "t11.a", 8
      parsed = YAML.parse(Superconf.to_yaml)
      parsed["t11"]["a"].as_i.should eq 8
      parsed["t11"]["b"].as_bool.should be_true
    end

    it "round-trips strings that look like YAML keywords" do
      Superconf.register "t13.s", "x"
      {"yes", "no", "null", "on", "123"}.each do |val|
        Superconf.set "t13.s", val
        YAML.parse(Superconf.to_yaml)["t13"]["s"].as_s.should eq val
      end
    end

    it "produces valid JSON" do
      Superconf.register "t12.a", 1
      JSON.parse(Superconf.to_json)["t12"]["a"].as_i.should eq 1
    end

    it "round-trips an option whose custom group differs from its key prefix" do
      o = Superconf.register "rt2.x", 1, group: "weird"
      o.set_from_string "5", Superconf::Source::ConfigFile, "seed"
      yaml = Superconf.to_yaml
      # Nested under the key prefix, not the custom group name — so it re-loads.
      YAML.parse(yaml)["rt2"]["x"].as_i.should eq 5
      YAML.parse(yaml)["weird"]?.should be_nil

      # Reloading the dump must land back on the same key (rt2.x), restoring 5.
      o.set_from_string "1", Superconf::Source::ConfigFile, "reset"
      o.value.should eq 1
      Superconf.load_yaml yaml
      o.value.should eq 5
    end

    it "round-trips a top-level key that collides with a group name" do
      flag = Superconf.register "rt3", false  # top-level scalar
      lvl = Superconf.register "rt3.level", 0 # group sharing that name
      flag.set_from_string "true", Superconf::Source::ConfigFile, "seed"
      lvl.set_from_string "7", Superconf::Source::ConfigFile, "seed"

      # Both must survive the dump as distinct keys (no duplicate "rt3" mapping
      # key clobbering the scalar), in YAML and JSON alike.
      y = YAML.parse(Superconf.to_yaml)
      y["rt3"].as_bool.should be_true
      y["rt3.level"].as_i.should eq 7
      JSON.parse(Superconf.to_json)["rt3"].as_bool.should be_true

      # And both re-load back onto their own keys.
      yaml = Superconf.to_yaml
      flag.set_from_string "false", Superconf::Source::ConfigFile, "reset"
      lvl.set_from_string "0", Superconf::Source::ConfigFile, "reset"
      Superconf.load_yaml yaml
      flag.value.should be_true
      lvl.value.should eq 7
    end

    it "stringifies/dumps an extreme Time::Span without overflowing" do
      # `Time::Span::MAX.total_seconds` rounds up to 2**63, one past Int64::MAX,
      # so the whole-number check must not blindly call `to_i64` (it would raise
      # OverflowError and crash every dump path). Such a value stays a float.
      o = Superconf.register "t16.span", 1.second
      o.set Time::Span::MAX
      o.stringify.should_not be_empty                   # no OverflowError
      Superconf.to_yaml.should contain "t16"            # dump succeeds too
      JSON.parse(Superconf.to_json)["t16"]["span"].as_f # valid JSON float
    end

    it "dumps a non-finite Float64 as JSON without crashing, and re-loads it" do
      # JSON has no literal for Infinity/NaN and `Float64#to_json` raises on one,
      # which would abort the whole dump. Such a value is reachable: parsing
      # "inf" yields Infinity. It must be emitted (as a string) and re-load.
      o = Superconf.register "t17.rate", 1.0
      o.set_from_string "inf", Superconf::Source::Env, "e"
      o.value.should eq Float64::INFINITY

      Superconf.to_json # no JSON::Error
      Superconf.get("t17.rate", Float64).should eq Float64::INFINITY

      # A finite Float64 still emits as a native JSON number.
      Superconf.register "t17.finite", 2.5
      JSON.parse(Superconf.to_json)["t17"]["finite"].as_f.should eq 2.5
    end

    it "dumps a non-finite Float64 as a native YAML float that re-reads as a float" do
      # `emit_yaml` promises numerics re-read with their native YAML types. A
      # bare `Infinity`/`NaN` would re-read as a *string*, breaking that and the
      # "re-loadable YAML" contract; the YAML special-float spellings re-read as
      # native floats.
      o = Superconf.register "t18.rate", 1.0
      o.set_from_string "inf", Superconf::Source::Env, "e"
      YAML.parse(Superconf.to_yaml)["t18"]["rate"].as_f.should eq Float64::INFINITY

      o.set_from_string "nan", Superconf::Source::Runtime, "r"
      YAML.parse(Superconf.to_yaml)["t18"]["rate"].as_f.nan?.should be_true

      # Round-trips back through superconf to the same value.
      Superconf.get("t18.rate", Float64).nan?.should be_true

      # A finite Float64 still emits as a native YAML number.
      Superconf.register "t18.finite", 2.5
      YAML.parse(Superconf.to_yaml)["t18"]["finite"].as_f.should eq 2.5
    end

    it "emits a sourceable env script, shell-quoting values" do
      Superconf.register "t15.name", "a b"
      io = IO::Memory.new
      Superconf.dump io, Superconf::Format::Env
      io.to_s.should contain "export T15_NAME='a b'"
    end
  end

  describe "set_default" do
    it "changes the default yet stays overridable by higher precedence" do
      Superconf.register "sd1.n", 1
      Superconf.set_default "sd1.n", 5
      Superconf.get("sd1.n", Int32).should eq 5
      Superconf["sd1.n"].source.should eq Superconf::Source::Default
      Superconf["sd1.n"].set_from_string "9", Superconf::Source::Env, "env"
      Superconf.get("sd1.n", Int32).should eq 9
    end

    it "updates the recorded default" do
      o = Superconf.register "sd2.n", 1
      Superconf.set_default "sd2.n", 7
      o.default.should eq 7
    end

    it "rejects an invalid new default without corrupting the recorded one" do
      o = Superconf.register "sd4.n", 10, validate: ->(n : Int32) { n > 0 }
      expect_raises(Superconf::Error, /invalid value -5/) do
        Superconf.set_default "sd4.n", -5
      end
      o.default.should eq 10 # unchanged by the rejected call
      o.value.should eq 10
    end

    it "does not clobber an already-set higher-precedence value" do
      o = Superconf.register "sd3.n", 1
      o.set 100, Superconf::Source::CommandLine, "cli"
      Superconf.set_default "sd3.n", 5
      o.value.should eq 100 # the CLI override stands
      o.default.should eq 5 # but the recorded default changed
    end
  end

  describe "aliasing" do
    it "shares one value between the two names, either way" do
      Superconf.register "al1.n", 1
      a = Superconf.register_alias "al1.promoted", "al1.n"
      a.alias_target.not_nil!.key.should eq "al1.n"

      Superconf.set "al1.promoted", 7 # write via alias
      Superconf.get("al1.n", Int32).should eq 7
      Superconf.get("al1.promoted", Int32).should eq 7

      Superconf.set "al1.n", 9 # write via target
      Superconf.get("al1.promoted", Int32).should eq 9
    end

    it "derives its own env/CLI/group surfaces" do
      Superconf.register "al2.n", 0
      a = Superconf.register_alias "myapp.count", "al2.n"
      Superconf.env_name(a).should eq "MYAPP_COUNT"
      a.cli.should eq "--myapp-count"
      a.group.should eq "myapp"
    end

    it "loads an env var through the alias at Env precedence" do
      Superconf.register "al3.n", 0
      Superconf.register_alias "al3.alt", "al3.n"
      ENV["AL3_ALT"] = "42"
      Superconf.load_env
      Superconf.get("al3.n", Int32).should eq 42
      Superconf["al3.n"].source.should eq Superconf::Source::Env
    ensure
      ENV.delete "AL3_ALT"
    end

    it "loads a CLI flag through the alias" do
      Superconf.register "al4.name", "a"
      Superconf.register_alias "al4.alt", "al4.name"
      Superconf.load_args ["--al4-alt=zebra"], consume: false
      Superconf.get("al4.name", String).should eq "zebra"
    end

    it "loads the alias key from a config file, flat and nested" do
      Superconf.register "al9.n", 0
      Superconf.register_alias "promo.al9", "al9.n"

      Superconf.load_yaml "promo.al9: 11" # flat dotted key
      Superconf.get("al9.n", Int32).should eq 11
      Superconf["al9.n"].source.should eq Superconf::Source::ConfigFile

      Superconf.load_yaml <<-YAML # nested group mapping
        promo:
          al9: 22
        YAML
      Superconf.get("al9.n", Int32).should eq 22
    end

    it "inherits the target's parsing and validation" do
      Superconf.register "al5.n", 10, validate: ->(n : Int32) { n > 0 }
      Superconf.register_alias "al5.alt", "al5.n"
      expect_raises(Superconf::Error, /invalid value 0/) do
        Superconf.set "al5.alt", 0
      end
    end

    it "exposes typed accessors via option_alias, sharing the value" do
      Superconf.lib_resize_interval = 1.second
      Superconf.myapp_refresh.should eq 1.second
      typeof(Superconf.myapp_refresh).should eq Time::Span
      Superconf.myapp_refresh = 3.seconds
      Superconf.lib_resize_interval.should eq 3.seconds
    ensure
      Superconf.lib_resize_interval = 0.2.seconds
    end

    it "registers an alias eagerly, even with the accessor unused" do
      Superconf["myapp.refresh"]?.should_not be_nil
    end

    it "resolves a chain when aliasing an alias" do
      Superconf.register "al6.n", 1
      Superconf.register_alias "al6.b", "al6.n"
      c = Superconf.register_alias "al6.c", "al6.b"
      c.alias_target.not_nil!.key.should eq "al6.n" # collapsed to the root
      Superconf.set "al6.c", 5
      Superconf.get("al6.n", Int32).should eq 5
    end

    it "raises on a duplicate alias key and on an unknown target" do
      Superconf.register "al7.n", 1
      Superconf.register_alias "al7.alt", "al7.n"
      expect_raises(ArgumentError, /already registered/) do
        Superconf.register_alias "al7.alt", "al7.n"
      end
      expect_raises(Superconf::Error, /unknown config option/) do
        Superconf.register_alias "al7.x", "al7.nope"
      end
    end

    it "omits aliases from value dumps but lists them in report" do
      Superconf.register "al8.n", 5
      Superconf.register_alias "al8.alt", "al8.n"
      YAML.parse(Superconf.to_yaml)["al8"]["alt"]?.should be_nil
      YAML.parse(Superconf.to_yaml)["al8"]["n"].as_i.should eq 5

      report = JSON.parse(String.build { |s| Superconf.dump s, Superconf::Format::Report })
      entry = report.as_a.find! { |e| e["key"] == "al8.alt" }
      entry["alias_of"].as_s.should eq "al8.n"
      entry["value"].as_i.should eq 5
    end
  end

  describe "default config path" do
    it "uses XDG_CONFIG_HOME when set" do
      saved = ENV["XDG_CONFIG_HOME"]?
      ENV["XDG_CONFIG_HOME"] = "/tmp/xdg-test"
      Superconf.default_config_path.should eq "/tmp/xdg-test/app/config.yml"
    ensure
      saved ? (ENV["XDG_CONFIG_HOME"] = saved) : ENV.delete("XDG_CONFIG_HOME")
    end

    it "falls back to ~/.config when XDG is unset" do
      saved = ENV["XDG_CONFIG_HOME"]?
      ENV.delete "XDG_CONFIG_HOME"
      Superconf.default_config_path.should eq "#{Path.home}/.config/app/config.yml"
    ensure
      ENV["XDG_CONFIG_HOME"] = saved if saved
    end
  end

  describe "iteration" do
    it "yields every registered option ordered by key" do
      Superconf.register "iter.zzz", 1
      Superconf.register "iter.aaa", 1
      keys = [] of String
      Superconf.each { |o| keys << o.key }
      keys.should eq keys.sort # globally ordered by key
      keys.should contain "iter.aaa"
      keys.should contain "iter.zzz"
    end
  end
end
