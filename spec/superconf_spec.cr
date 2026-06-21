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

    it "parses a Char option (single character)" do
      Superconf.register "t14.glyph", '▮'
      Superconf["t14.glyph"].set_from_string "x", Superconf::Source::Env, "e"
      Superconf.get("t14.glyph", Char).should eq 'x'
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

    it "applies CLI flags at CommandLine precedence" do
      Superconf.register "t8.name", "a"
      Superconf.register "t8.on", false
      Superconf.load_args ["--t8-name=zebra", "--t8-on"], consume: false
      Superconf.get("t8.name", String).should eq "zebra"
      Superconf.get("t8.on", Bool).should be_true
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

    it "does not clobber an already-set higher-precedence value" do
      o = Superconf.register "sd3.n", 1
      o.set 100, Superconf::Source::CommandLine, "cli"
      Superconf.set_default "sd3.n", 5
      o.value.should eq 100 # the CLI override stands
      o.default.should eq 5 # but the recorded default changed
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
end
