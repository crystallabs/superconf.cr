require "./spec_helper"

# The surfaces for a program that changes and saves options while it runs:
# change notifications, a load at runtime precedence, resets, a dump of a
# selection of options, and a deferred `--dump-config`.

module Superconf
  option "rt.count", 4, description: "runtime spec option"
  option "rt.name", "plain", description: "runtime spec option"
  option_alias "rt.alias_count", "rt.count", Int32
end

describe Superconf do
  describe "#on_change" do
    it "runs the block after the value changes, from any source" do
      seen = [] of Int32
      handle = Superconf.on_change("rt.count") { seen << Superconf.rt_count }
      Superconf.rt_count = 5
      Superconf.load_yaml "rt: {count: 6}", "spec", Superconf::Source::Runtime
      Superconf.load_args ["--rt-count=7"], consume: false # outranked by the runtime value: no change
      Superconf.rt_count = 7
      Superconf.rt_count = 7 # the same value: no change
      seen.should eq [5, 6, 7]
      Superconf.off_change("rt.count", handle).should be_true
      Superconf.off_change("rt.count", handle).should be_false
      Superconf.rt_count = 8
      seen.should eq [5, 6, 7]
    ensure
      Superconf.reset "rt.count"
    end

    it "lets a block unregister itself while it runs, without skipping the next" do
      seen = [] of String
      first = Proc(Nil).new { }
      first = Superconf.on_change("rt.count") do
        seen << "first"
        Superconf.off_change "rt.count", first
      end
      second = Superconf.on_change("rt.count") { seen << "second" }
      Superconf.rt_count = 13
      Superconf.rt_count = 14
      seen.should eq ["first", "second", "second"]
      Superconf.off_change("rt.count", second).should be_true
    ensure
      Superconf.reset "rt.count"
    end

    it "reaches a block registered on an alias, and reports a change through either name" do
      seen = 0
      handle = Superconf.on_change("rt.alias_count") { seen += 1 }
      Superconf.rt_count = 9
      Superconf.rt_alias_count = 10
      seen.should eq 2
      Superconf["rt.count"].off_change(handle).should be_true
    ensure
      Superconf.reset "rt.count"
    end
  end

  describe ".reset" do
    it "puts the option back to its default, at default precedence, notifying" do
      seen = [] of Int32
      handle = Superconf.on_change("rt.count") { seen << Superconf.rt_count }
      Superconf.rt_count = 11
      Superconf.reset "rt.count"
      Superconf.rt_count.should eq 4
      Superconf["rt.count"].source.should eq Superconf::Source::Default
      Superconf["rt.count"].origin.should eq "default"
      Superconf.configured?("rt.count").should be_false
      seen.should eq [11, 4]
      Superconf.load_yaml "rt: {count: 12}", "spec" # a file applies again after the reset
      Superconf.rt_count.should eq 12
      Superconf.reset "rt.alias_count" # through the alias
      Superconf.rt_count.should eq 4
      Superconf.off_change "rt.count", handle
    ensure
      Superconf.reset "rt.count"
    end
  end

  describe ".parse_yaml / .load_yaml of a parsed document" do
    it "applies a document parsed once, under the origin given" do
      document = Superconf.parse_yaml "rt: {count: 31}", "config file x.yml"
      document["rt"]["count"].as_i.should eq 31
      Superconf.rt_count.should_not eq 31 # parsing applies nothing
      Superconf.load_yaml document, "config file x.yml"
      Superconf.rt_count.should eq 31
      Superconf["rt.count"].source.should eq Superconf::Source::ConfigFile
      Superconf["rt.count"].origin.should eq "config file x.yml (rt.count)"
    ensure
      Superconf.reset "rt.count"
    end

    it "raises Error naming the origin for malformed text" do
      expect_raises(Superconf::Error, /cannot parse config file x.yml/) do
        Superconf.parse_yaml "rt: {count: [", "config file x.yml"
      end
    end

    it "raises Error naming the origin for a document that is not a mapping" do
      ["- rt.count: 5", "5", "just text"].each do |text|
        expect_raises(Superconf::Error, /cannot load config file x.yml: the document is not a mapping/) do
          Superconf.parse_yaml text, "config file x.yml"
        end
      end
      expect_raises(Superconf::Error, /not a mapping/) do
        Superconf.load_yaml YAML::Any.new([] of YAML::Any), "config file x.yml"
      end
    end

    it "takes an empty document as an empty configuration" do
      Superconf.parse_yaml("# only a comment\n", "config file x.yml").raw.should be_nil
      Superconf.load_yaml "", "config file x.yml"
      Superconf.rt_count.should eq 4
    end

    it "raises Error for a group of options given a value, and takes an empty group" do
      expect_raises(Superconf::Error, /invalid value for "rt" \(config file x.yml\): a group of options takes a mapping/) do
        Superconf.load_yaml "rt: 5", "config file x.yml"
      end
      expect_raises(Superconf::Error, /a group of options takes a mapping/) do
        Superconf.load_yaml "rt: [1, 2]", "config file x.yml"
      end
      Superconf.load_yaml "rt:\n", "config file x.yml"
      Superconf.rt_count.should eq 4
    end

    it "names the path once when the file cannot be read" do
      path = "/nonexistent/superconf-spec-#{Process.pid}.yml"
      ex = expect_raises(Superconf::Error) { Superconf.load_file path }
      ex.message.should eq "cannot read config file #{path}: No such file or directory"
    end
  end

  describe ".load_yaml / .load_file at a source" do
    it "loads at file precedence by default, below a runtime value" do
      Superconf.rt_count = 20
      Superconf.load_yaml "rt: {count: 21}", "spec"
      Superconf.rt_count.should eq 20
    ensure
      Superconf.reset "rt.count"
    end

    it "loads at runtime precedence when asked, over a runtime value" do
      Superconf.rt_count = 20
      path = File.tempname("superconf-runtime", ".yml")
      File.write path, "rt:\n  count: 22\n  name: \"from file\"\n"
      Superconf.load_file path, Superconf::Source::Runtime
      Superconf.rt_count.should eq 22
      Superconf.rt_name.should eq "from file"
      Superconf["rt.count"].source.should eq Superconf::Source::Runtime
      Superconf["rt.count"].origin.should eq "config file #{path} (rt.count)"
    ensure
      Superconf.reset "rt.count"
      Superconf.reset "rt.name"
      File.delete path if path
    end
  end

  describe ".dump with a selection" do
    it "dumps only the options the block selects, re-loadably" do
      Superconf.rt_count = 30
      yaml = Superconf.to_yaml { |opt| opt.key.starts_with?("rt.") && !opt.at_default? }
      yaml.should eq "---\nrt:\n  count: 30\n"
      json = Superconf.to_json(&.key.starts_with?("rt."))
      json.should contain %("count": 30)
      json.should contain %("name": "plain")
      json.should_not contain "alias_count" # aliases carry no value of their own
      Superconf.reset "rt.count"
      Superconf.load_yaml yaml, "spec"
      Superconf.rt_count.should eq 30
      env = String.build { |s| Superconf.dump(s, Superconf::Format::Env) { |opt| opt.key == "rt.count" } }
      env.should eq "export RT_COUNT='30'\n"
      pretty = String.build { |s| Superconf.dump(s, Superconf::Format::Pretty) { |opt| opt.key == "rt.count" } }
      pretty.lines.size.should eq 3
      report = String.build { |s| Superconf.dump(s, Superconf::Format::Report) { |opt| opt.key.starts_with?("rt.") } }
      report.should contain %("key": "rt.alias_count") # the report lists aliases
      nothing = String.build { |s| Superconf.dump(s) { |_| false } }
      nothing.should eq "--- {}\n"
    ensure
      Superconf.reset "rt.count"
    end
  end

  describe ".configured?" do
    it "answers by source: a value set equal to the default counts, a changed default does not" do
      Superconf.configured?("rt.count").should be_false
      Superconf.rt_count = 4 # the default, chosen
      Superconf["rt.count"].at_default?.should be_true
      Superconf.configured?("rt.count").should be_true
      Superconf.reset "rt.count"
      Superconf.configured?("rt.count").should be_false
      Superconf.set_default "rt.count", 5
      Superconf.rt_count.should eq 5
      Superconf.configured?("rt.count").should be_false
      Superconf.load_yaml "rt: {count: 5}", "spec" # the (new) default, pinned by a file
      Superconf.configured?("rt.count").should be_true
      Superconf.configured?("rt.alias_count").should be_true # the shared value's source
    ensure
      Superconf.reset "rt.count"
      Superconf.set_default "rt.count", 4
    end
  end

  describe ".load_args --dump-config FORMAT" do
    it "takes the next word as the format only when it names one" do
      argv = ["--dump-config", "notes.md"]
      Superconf.load_args argv, defer_dump: true
      argv.should eq ["notes.md"] # the application's, not a format
      Superconf.pending_dump.should eq Superconf::Format::Yaml
      Superconf.pending_dump = nil
      argv = ["--dump-config", "JSON", "notes.md"]
      Superconf.load_args argv, defer_dump: true
      argv.should eq ["notes.md"]
      Superconf.pending_dump.should eq Superconf::Format::Json
      Superconf.dump_format?("text").should eq Superconf::Format::Pretty
      Superconf.dump_format?("notes.md").should be_nil
    ensure
      Superconf.pending_dump = nil
    end

    it "refuses a format given with = that names none instead of dumping YAML" do
      Superconf.pending_dump = nil
      error = expect_raises(Superconf::Error, /unknown dump format "jsn"/) do
        Superconf.load_args ["--dump-config=jsn"], consume: false, defer_dump: true
      end
      (error.message || "").should contain "yaml|json|env|pretty|report"
      Superconf.pending_dump.should be_nil
      Superconf.load_args ["--dump-config=YAML"], consume: false, defer_dump: true
      Superconf.pending_dump.should eq Superconf::Format::Yaml
    ensure
      Superconf.pending_dump = nil
    end
  end

  describe ".default_config_path" do
    it "names another application's file in the same place when asked" do
      previous = ENV["XDG_CONFIG_HOME"]?
      ENV["XDG_CONFIG_HOME"] = "/tmp/xdg"
      Superconf.default_config_path.should eq "/tmp/xdg/#{Superconf.app_name}/config.yml"
      Superconf.default_config_path("toolkit").should eq "/tmp/xdg/toolkit/config.yml"
    ensure
      if previous
        ENV["XDG_CONFIG_HOME"] = previous
      else
        ENV.delete "XDG_CONFIG_HOME"
      end
    end
  end

  describe ".load_args with defer_dump" do
    it "notes the dump for dump_pending instead of dumping" do
      Superconf.pending_dump.should be_nil
      Superconf.load_args ["--dump-config", "json", "--rt-count=40"], consume: false, defer_dump: true
      Superconf.pending_dump.should eq Superconf::Format::Json
      Superconf.rt_count.should eq 40 # the other flags still apply
      Superconf.load_args ["--dump-config"], consume: false, defer_dump: true
      Superconf.pending_dump.should eq Superconf::Format::Yaml
    ensure
      Superconf.pending_dump = nil # left pending, a later `dump_pending` would exit the spec run
      Superconf.reset "rt.count"
    end
  end
end
