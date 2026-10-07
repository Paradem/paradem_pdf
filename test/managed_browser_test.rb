require "test_helper"
require "paradem_pdf"

class FakeStdin
  attr_reader :closed

  def initialize
    @closed = false
  end

  def close
    @closed = true
  end

  def closed?
    @closed
  end
end

class FakeWaitThread
  attr_reader :pid, :joins

  def initialize(pid:, exit_after_joins:)
    @pid = pid
    @exit_after_joins = exit_after_joins
    @joins = 0
  end

  def join(timeout = nil)
    @joins += 1
    (@joins > @exit_after_joins) ? self : nil
  end

  def value
    Struct.new(:success?, :exitstatus).new(true, 0)
  end
end

class ManagedBrowserTest < Minitest::Test
  def setup
    @ios = []
  end

  def teardown
    @ios.each { |io| io.close unless io.closed? }
  end

  def pipe_stdout(contents)
    reader, writer = IO.pipe
    @ios.concat([reader, writer])
    unless contents.nil?
      writer.write(contents)
      writer.close
    end
    reader
  end

  def endpoint_stdout
    pipe_stdout("ws://localhost:3000/devtools/browser/abc\n")
  end

  def stub_spawn(stdin, stdout, wait_thr)
    captured = nil
    Open3.stub(:popen2, ->(*args, **kwargs) {
      captured = [args, kwargs]
      [stdin, stdout, wait_thr]
    }) { yield -> { captured } }
  end

  def test_browser_error_is_a_paradem_pdf_error
    assert_operator ParademPdf::BrowserError, :<, ParademPdf::Error
  end

  def test_open_spawns_launcher_and_returns_endpoint
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, endpoint_stdout, wait_thr) do |captured|
      browser = ParademPdf::Browser.open(options: {}, root_path: "/app")

      assert_equal "ws://localhost:3000/devtools/browser/abc", browser.endpoint
      refute browser.closed?

      args, kwargs = captured.call
      env, *command = args
      assert_equal "1", env["PARADEM_PDF_BROWSER_LAUNCHER"]
      assert_equal "node", command.first
      assert_equal File.expand_path("../lib/paradem_pdf/browser.js", __dir__), command[1]
      assert_equal "/app", kwargs[:chdir]
      assert_equal true, kwargs[:pgroup]
    end
  end

  def test_open_maps_options_to_launcher_payload
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, endpoint_stdout, wait_thr) do |captured|
      ParademPdf::Browser.open(
        options: {executable_path: "/chrome", launch_args: ["--foo"], browser: "firefox",
                  launch_timeout: 20_000, debug: {headless: false}},
        root_path: "/app"
      )

      payload = JSON.parse(captured.call.first.last)
      assert_equal "/chrome", payload["executablePath"]
      assert_equal ["--foo"], payload["args"]
      assert_equal "firefox", payload["browser"]
      assert_equal 20_000, payload["timeout"]
      assert_equal false, payload["headless"]
    end
  end

  def test_open_defaults_headless_to_true
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, endpoint_stdout, wait_thr) do |captured|
      ParademPdf::Browser.open(options: {}, root_path: "/app")
      assert_equal true, JSON.parse(captured.call.first.last)["headless"]
    end
  end

  def test_open_raises_on_unexpected_exit
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, pipe_stdout(""), wait_thr) do
      Process.stub(:kill, ->(_sig, _target) {}) do
        assert_raises(ParademPdf::BrowserError) do
          ParademPdf::Browser.open(options: {}, root_path: "/app")
        end
      end
    end
  end

  def test_open_raises_on_unreadable_output
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, pipe_stdout("garbage\nmore garbage\n"), wait_thr) do
      Process.stub(:kill, ->(_sig, _target) {}) do
        assert_raises(ParademPdf::BrowserError) do
          ParademPdf::Browser.open(options: {}, root_path: "/app")
        end
      end
    end
  end

  def test_open_raises_on_timeout
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)

    stub_spawn(stdin, pipe_stdout(nil), wait_thr) do
      Process.stub(:kill, ->(_sig, _target) {}) do
        assert_raises(ParademPdf::BrowserError) do
          ParademPdf::Browser.open(options: {}, root_path: "/app", timeout: 0.01)
        end
      end
    end
  end

  def test_open_rejects_sandbox_bypass_environment_before_spawning
    ENV["GROVER_NO_SANDBOX"] = "true"
    Open3.stub(:popen2, ->(*_args, **_kwargs) { flunk "must not spawn" }) do
      assert_raises(ArgumentError) { ParademPdf::Browser.open(options: {}, root_path: "/app") }
    end
  ensure
    ENV.delete("GROVER_NO_SANDBOX")
  end

  def test_open_rejects_bypass_launch_args_before_spawning
    Open3.stub(:popen2, ->(*_args, **_kwargs) { flunk "must not spawn" }) do
      ["--no-sandbox", "--disable-setuid-sandbox", "--disable-web-security", "--ignore-certificate-errors"].each do |flag|
        assert_raises(ArgumentError) do
          ParademPdf::Browser.open(options: {launch_args: [flag]}, root_path: "/app")
        end
      end
    end
  end

  def test_close_closes_stdin_and_reaps_without_signaling
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)
    browser = ParademPdf::Browser.new(endpoint: "ws://x", stdin: stdin, stdout: endpoint_stdout, wait_thr: wait_thr)

    signals = []
    Process.stub(:kill, ->(sig, target) { signals << [sig, target] }) { browser.close }

    assert stdin.closed?
    assert browser.closed?
    assert_empty signals
    assert_operator wait_thr.joins, :>=, 1
  end

  def test_close_force_path_signals_process_group
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 4)
    browser = ParademPdf::Browser.new(endpoint: "ws://x", stdin: stdin, stdout: endpoint_stdout, wait_thr: wait_thr)

    signals = []
    Process.stub(:kill, ->(sig, target) { signals << [sig, target] }) do
      assert_raises(ParademPdf::BrowserError) { browser.close }
    end

    assert stdin.closed?
    assert_equal [["TERM", -12345], ["KILL", -12345]], signals
  end

  def test_close_is_idempotent
    stdin = FakeStdin.new
    wait_thr = FakeWaitThread.new(pid: 12345, exit_after_joins: 0)
    browser = ParademPdf::Browser.new(endpoint: "ws://x", stdin: stdin, stdout: endpoint_stdout, wait_thr: wait_thr)

    signals = []
    Process.stub(:kill, ->(sig, target) { signals << [sig, target] }) do
      browser.close
      browser.close
    end

    assert_empty signals
    assert_equal 1, wait_thr.joins
  end
end
