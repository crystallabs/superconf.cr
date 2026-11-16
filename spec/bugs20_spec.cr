require "./spec_helper"

describe Superconf do
  describe ".set on a String? option" do
    it "accepts a String value, a member of the option's value type" do
      Superconf.register "b20.title", nil.as(String?), parse: Superconf::ENV_STRING
      Superconf.set "b20.title", "hello"
      Superconf.get("b20.title", String?).should eq "hello"
      Superconf.set "b20.title", nil
      Superconf.get("b20.title", String?).should be_nil
    end

    it "still raises for a value of an unrelated type" do
      Superconf.register "b20.other", nil.as(String?), parse: Superconf::ENV_STRING
      expect_raises(Superconf::Error, /not Option/) { Superconf.set "b20.other", 5 }
    end
  end

  describe ".set_default on a String? option" do
    it "accepts a String value and records it as the default" do
      Superconf.register "b20.path", nil.as(String?), parse: Superconf::ENV_STRING
      Superconf.set_default "b20.path", "/tmp/x"
      Superconf.get("b20.path", String?).should eq "/tmp/x"
      Superconf["b20.path"].default_string.should eq "/tmp/x"
      Superconf.configured?("b20.path").should be_false
    end
  end
end
