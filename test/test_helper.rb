require "minitest/autorun"
require "open3"
require "rbconfig"

module StandaloneRuby
  def run_ruby(source)
    Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", source)
  end
end
