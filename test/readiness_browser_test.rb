require "test_helper"
require "support/browser_fixture"
require "tmpdir"
require "fileutils"
require "support/readiness_fixture"

class ReadinessObserverGuardTest < Minitest::Test
  def test_benchmark_records_json_before_failing_either_gate
    Dir.mktmpdir("paradem-pdf-benchmark-gates-") do |directory|
      [[true, true, true], [false, true, false], [true, false, false]].each do |appearance, warm, success|
        script = "require 'support/readiness_benchmark'; ReadinessBenchmark.finish(ARGV[0], {appearance_gate: #{appearance}, warm_target_gate: #{warm}})"
        output, _errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-Itest", "-e", script, directory)
        assert_equal success, status.success?
        expected = {"appearance_gate" => appearance, "warm_target_gate" => warm}
        assert_equal expected, JSON.parse(File.read(File.join(directory, "benchmark.json")))
        assert_equal expected, JSON.parse(output.lines.last)
      end
    end
  end

  def test_rejects_missing_context_cleanup_disconnect_and_worker_deadline
    record = {"contexts" => 1, "events" => %w[context-open context-close disconnect].each_with_index.map { |name, index| {"name" => name, "at" => index} }}
    BrowserFixture.stub(:check_records, true) do
      ReadinessFixture.stub(:records, [record]) { ReadinessFixture.check_records("unused") }
      [record.merge("contexts" => 2),
        record.merge("events" => record["events"].reject { |event| event["name"] == "context-close" }),
        record.merge("events" => record["events"].reject { |event| event["name"] == "disconnect" }),
        record.merge("events" => record["events"] + [{"name" => "worker-deadline", "at" => 4}])].each do |invalid|
        ReadinessFixture.stub(:records, [invalid]) { assert_raises(RuntimeError) { ReadinessFixture.check_records("unused") } }
      end
    end
  end
end

class ReadinessBrowserTest < Minitest::Test
  def setup
    skip "Resource browser proof disabled; set PARADEM_PDF_READINESS_BROWSER=1" unless ENV["PARADEM_PDF_READINESS_BROWSER"] == "1"
    BrowserFixture.validate!(ENV)
  end

  def test_selected_media_survives_load_readiness_and_print_and_corrupt_font_is_not_cached
    root = ENV["PARADEM_PDF_READINESS_ARTIFACTS"]
    temporary = root.nil?
    directory = root ? File.join(root, "media-regression") : Dir.mktmpdir("paradem-pdf-media-")
    FileUtils.mkdir_p(directory)
    output = BrowserFixture.run(RbConfig.ruby, "-Ilib", "-Itest",
      File.expand_path("support/readiness_fixture.rb", __dir__), "--media-regression", directory, timeout: 150)
    result = JSON.parse(output.lines.last)
    assert_equal 10, result.fetch("iterations")
    assert_equal 20, result.fetch("conversions")
    assert_empty result.fetch("failures")
  ensure
    FileUtils.remove_entry(directory) if temporary && directory && File.directory?(directory)
  end

  def test_parallel_headers_and_footers_keep_print_media_and_reject_corrupt_fonts
    root = ENV["PARADEM_PDF_READINESS_ARTIFACTS"]
    temporary = root.nil?
    directory = root ? File.join(root, "parallel-media-regression") : Dir.mktmpdir("paradem-pdf-parallel-media-")
    FileUtils.mkdir_p(directory)
    output = BrowserFixture.run(RbConfig.ruby, "-Ilib", "-Itest",
      File.expand_path("support/readiness_fixture.rb", __dir__), "--parallel-media-regression", directory, timeout: 180)
    result = JSON.parse(output.lines.last)
    assert_equal 10, result.fetch("iterations")
    assert_operator result.fetch("conversions"), :>=, 80
    assert_empty result.fetch("failures")
  ensure
    FileUtils.remove_entry(directory) if temporary && directory && File.directory?(directory)
  end

  %w[portrait landscape held bad-font bad-image bad-data bad-style stall bad-decoration custom explicit-wait optout screen idle-control].each do |scenario|
    define_method("test_real_#{scenario.tr("-", "_")}") do
      root = ENV["PARADEM_PDF_READINESS_ARTIFACTS"]
      temporary = root.nil?
      directory = root ? File.join(root, scenario) : Dir.mktmpdir("paradem-pdf-readiness-")
      FileUtils.mkdir_p(directory)
      # Subprocess isolates native Grover configuration and worker observers.
      output = BrowserFixture.run(RbConfig.ruby, "-Ilib", "-Itest",
        File.expand_path("support/readiness_fixture.rb", __dir__), "--render", directory, scenario, timeout: 150)
      result = JSON.parse(output.lines.last)
      assert_equal scenario, result.fetch("scenario")
      assert_operator result.fetch("conversions"), :>=, 1
    ensure
      FileUtils.remove_entry(directory) if temporary && directory && File.directory?(directory)
    end
  end
end
