require "test_helper"
require "support/browser_fixture"
require "tmpdir"

class BrowserFixtureGuardTest < Minitest::Test
  def test_enabled_fixture_rejects_missing_font_instead_of_skipping
    error = assert_raises(ArgumentError) { BrowserFixture.validate!({}) }
    assert_match(/PARADEM_PDF_TEST_FONT/, error.message)
  end

  def test_fixture_rejects_sandbox_bypass_before_prerequisite_checks
    error = assert_raises(ArgumentError) { BrowserFixture.validate!({"GROVER_NO_SANDBOX" => "true"}) }
    assert_match(/security/, error.message)
  end

  def test_fixture_rejects_external_node_preloads
    assert_raises(ArgumentError) { BrowserFixture.validate!({"NODE_OPTIONS" => "--require unknown.cjs"}) }
  end

  def test_fixture_rejects_missing_chrome_after_readable_font
    error = assert_raises(ArgumentError) { BrowserFixture.validate!({"PARADEM_PDF_TEST_FONT" => __FILE__}) }
    assert_match(/PUPPETEER_EXECUTABLE_PATH/, error.message)
  end

  def test_subprocess_deadline_terminates_only_owned_child
    error = assert_raises(RuntimeError) { BrowserFixture.run(RbConfig.ruby, "-e", "sleep 10", timeout: 0.01) }
    assert_match(/deadline/, error.message)
  end

  def test_observer_security_and_owned_cleanup_without_browser
    output = BrowserFixture.run("node", File.expand_path("support/browser_observer.cjs", __dir__), "--self-test")
    assert_includes output, "Browser observer self-check passed"
  end
end

class BrowserTest < Minitest::Test
  def setup
    skip "Real browser disabled; set PARADEM_PDF_BROWSER=1" unless ENV["PARADEM_PDF_BROWSER"] == "1"
    BrowserFixture.validate!(ENV)
  end

  def test_real_portrait_pages_fonts_positions_and_changing_totals
    check_document("portrait")
  end

  def test_real_landscape_pages_fonts_positions_and_changing_totals
    check_document("landscape")
  end

  def check_document(orientation)
    Dir.mktmpdir("paradem-pdf-browser-") do |directory|
      output = BrowserFixture.run(RbConfig.ruby, "-Ilib", "-Itest",
        File.expand_path("support/browser_fixture.rb", __dir__), "--render", directory, orientation, timeout: 900)
      result = JSON.parse(output.lines.last)
      assert_equal [2, 3], result.fetch("pages")
      assert_equal 12, result.fetch("conversions")
      assert_equal 2, result.fetch("cleanups")
      assert_equal 1, result.fetch("batch_cleanups")
    end
  end
end
