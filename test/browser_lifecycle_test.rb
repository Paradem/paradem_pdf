require "test_helper"
require "minitest/mock"
require "paradem_pdf"
require "support/pdf_helpers"

class BrowserLifecycleTest < Minitest::Test
  include PdfHelpers

  class Waiter
    attr_reader :pid, :joins

    def initialize(results: [true], success: true)
      @pid = 987_654
      @results = results
      @success = success
      @joins = []
    end

    def join(timeout = nil)
      @joins << timeout
      @results.shift ? self : nil
    end

    def value
      Struct.new(:success?, :exitstatus).new(@success, @success ? 0 : 1)
    end
  end

  def setup
    @saved_options = Grover.configuration.options
    Grover.configuration.options = {}
    @stdin, @stdin_reader = IO.pipe.reverse
    @stdout, @stdout_writer = IO.pipe
    @signals = []
  end

  def teardown
    Grover.configuration.options = @saved_options
    [@stdin, @stdin_reader, @stdout, @stdout_writer].each { |io| io.close unless io.closed? }
  end

  def browser(waiter)
    ParademPdf::Browser.new(endpoint: "ws://fake", stdin: @stdin, stdout: @stdout, wait_thr: waiter)
  end

  def without_signals
    Process.stub(:kill, ->(signal, target) { @signals << [signal, target] }) { yield }
  end

  def fake_launch(waiter)
    Open3.stub(:popen2, ->(*, **) { [@stdin, @stdout, waiter] }) { yield }
  end

  def test_default_batch_timeout_is_finite
    seen = nil
    fake_launch(Waiter.new) do
      ParademPdf::Browser.stub(:read_endpoint, ->(_, timeout) {
        seen = timeout
        "ws://fake"
      }) do
        ParademPdf::Document.browser { |_| }
      end
    end
    assert_equal 30, seen
  end

  def test_larger_native_launch_timeout_extends_the_endpoint_deadline
    seen = nil
    fake_launch(Waiter.new) do
      ParademPdf::Browser.stub(:read_endpoint, ->(_, timeout) {
        seen = timeout
        "ws://fake"
      }) do
        ParademPdf::Browser.open(options: {launch_timeout: 60_000})
      end
    end
    assert_in_delta 60.0, seen, 0.001
  end

  def test_document_body_metadata_launch_timeout_extends_the_endpoint_deadline
    seen = nil
    html = '<meta name="grover-launch_timeout" content="60000"><body>body</body>'
    @stdout_writer.write("ws://fake\n")
    Open3.stub(:popen2, ->(*, **) { [@stdin, @stdout, Waiter.new] }) do
      ParademPdf::Browser.stub(:read_endpoint, ->(_, timeout) {
        seen = timeout
        "ws://fake"
      }) do
        with_conversion do
          ParademPdf::Document.new(doc_type: "test", body_html: html, origin: "https://example.test", locale: "en").to_pdf
        end
      end
    end
    assert_in_delta 60.0, seen, 0.001
  end

  def test_fixture_launch_timeout_bounds_the_endpoint_deadline_in_seconds
    seen = nil
    fake_launch(Waiter.new) do
      ParademPdf::Browser.stub(:read_endpoint, ->(_, timeout) {
        seen = timeout
        "ws://fake"
      }) do
        ParademPdf::Browser.open(options: {launch_timeout: 20_000})
      end
    end
    # 20_000 ms (20 s) sits at or below the finite 30 s default floor, so the
    # endpoint wait stays on the seconds scale and is never 20_000 seconds.
    assert_operator seen, :>=, 20.0
    assert_operator seen, :<=, 30.0
  end

  def test_blank_or_non_websocket_explicit_endpoint_is_rejected_at_construction
    [["browser_ws_endpoint", ""], ["browserWsEndpoint", ""], ["browser_ws_endpoint", "http://example.test"]].each do |key, value|
      ParademPdf::Browser.stub(:open, ->(**) { flunk "Invalid endpoint reached launch" }) do
        error = assert_raises(ArgumentError) do
          ParademPdf::Document.new(doc_type: "test", body_html: "body", origin: "https://example.test",
            locale: "en", options: {key => value})
        end
        assert_match(/ws:\/\//, error.message)
      end
    end
  end

  def test_explicit_endpoint_skips_managed_launch
    document = ParademPdf::Document.new(doc_type: "test", body_html: "body", origin: "https://example.test",
      locale: "en", options: {browser_ws_endpoint: "ws://explicit"})
    ParademPdf::Browser.stub(:open, ->(**) { flunk "Explicit endpoint launched a managed browser" }) do
      with_conversion(endpoint: "ws://explicit") { document.to_pdf }
    end
  end

  def test_caller_browser_takes_precedence_over_explicit_endpoint
    caller = Struct.new(:endpoint, :closed) do
      def close
        self.closed = true
      end
    end.new("ws://caller", false)
    document = ParademPdf::Document.new(doc_type: "test", body_html: "body", origin: "https://example.test",
      locale: "en", options: {browser_ws_endpoint: "ws://explicit"})
    ParademPdf::Browser.stub(:open, ->(**) { flunk "Endpoint precedence launched a managed browser" }) do
      with_conversion(endpoint: "ws://caller") { document.to_pdf(browser: caller) }
    end
    refute caller.closed
  end

  def test_invalid_timeouts_are_rejected_before_launch
    [0, -1, Float::INFINITY, Float::NAN, "1", false].each do |timeout|
      Open3.stub(:popen2, ->(*, **) { flunk "Invalid timeout launched a process" }) do
        assert_raises(ArgumentError) { ParademPdf::Browser.open(options: {}, timeout: timeout) }
      end
    end
  end

  def test_failed_launch_never_signals_a_reaped_process_and_closes_descriptors
    waiter = Waiter.new
    @stdout_writer.close
    without_signals do
      fake_launch(waiter) do
        assert_raises(ParademPdf::BrowserError) { ParademPdf::Browser.open(options: {}, timeout: 0.01) }
      end
    end
    assert_empty @signals
    assert @stdin.closed?
    assert @stdout.closed?
  end

  def test_forced_cleanup_signals_only_owned_group_and_reports_failure
    waiter = Waiter.new(results: [false, false, false, false, true])
    without_signals do
      assert_raises(ParademPdf::BrowserError) { browser(waiter).close }
    end
    assert_equal [["TERM", -waiter.pid], ["KILL", -waiter.pid]], @signals
    assert waiter.joins.all? { |grace| grace.is_a?(Numeric) && grace.finite? && grace >= 0 }
    assert @stdout.closed?
  end

  def test_unreaped_launcher_fails_with_bounded_final_join
    waiter = Waiter.new(results: [])
    without_signals do
      error = assert_raises(ParademPdf::BrowserError) { browser(waiter).close }
      assert_match(/reap/, error.message)
    end
    refute_includes waiter.joins, nil
  end

  def test_nonzero_close_status_is_not_success
    owned = browser(Waiter.new(success: false))
    assert_raises(ParademPdf::BrowserError) { owned.close }
    assert owned.closed?
    assert @stdout.closed?
    assert_raises(ParademPdf::BrowserError) { owned.endpoint }
    owned.close
  end

  def test_close_failure_preserves_an_active_render_error_as_cause
    owned = browser(Waiter.new(success: false))
    original = RuntimeError.new("conversion failed")
    failure = assert_raises(ParademPdf::BrowserError) do
      raise original
    ensure
      owned.close
    end
    assert_same original, failure.cause
  end

  def test_endpoint_deadline_does_not_leave_a_reader_thread
    before = Thread.list
    @stdout_writer.write("ws://partial")
    assert_nil ParademPdf::Browser.send(:read_endpoint, @stdout, 0.01)
    assert_empty Thread.list - before
  ensure
    (Thread.list - before).each { |thread| thread.kill.join }
  end

  def test_endpoint_read_handles_noise_and_complete_buffered_lines
    @stdout_writer.write("launcher notice\nws://fake\n")
    assert_equal "ws://fake", ParademPdf::Browser.send(:read_endpoint, @stdout, 0.1)
  end

  def test_native_close_rejection_is_a_nonzero_exit
    source = <<~JS
      const vm = require('vm');
      const fs = require('fs');
      const EventEmitter = require('events');
      const fakeProcess = new EventEmitter();
      fakeProcess.stdin = new EventEmitter();
      fakeProcess.stdin.resume = () => {};
      fakeProcess.argv = ['node', 'launcher', '{"devtools":true}'];
      fakeProcess.cwd = () => process.cwd();
      fakeProcess.stdout = {write: () => {}};
      let errors = '';
      fakeProcess.stderr = {write: value => { errors += value; }};
      const exits = [];
      let launchParams;
      fakeProcess.exit = code => exits.push(code);
      const loader = name => name === 'module' ? require('module') : {
        launch: async options => {
          launchParams = options;
          return {wsEndpoint: () => 'ws://fake', close: async () => { throw new Error('native close failed'); }};
        }
      };
      loader.resolve = () => 'fake-puppeteer';
      vm.runInNewContext(fs.readFileSync(process.argv[1], 'utf8'), {require: loader, process: fakeProcess});
      setImmediate(() => {
        fakeProcess.stdin.emit('end');
        setImmediate(() => console.log(JSON.stringify({exits, errors, launchParams})));
      });
    JS
    output, stderr, status = Open3.capture3("node", "-e", source, File.expand_path("../lib/paradem_pdf/browser.js", __dir__))
    assert status.success?, stderr
    result = JSON.parse(output)
    assert_equal [1], result.fetch("exits")
    assert_includes result.fetch("errors"), "native close failed"
    assert_equal true, result.fetch("launchParams")["devtools"]
  end

  def capture_launch
    payload = nil
    launch_root = nil
    @stdout_writer.write("ws://fake\n")
    Open3.stub(:popen2, ->(*args, **kwargs) {
      payload = JSON.parse(args.last)
      launch_root = kwargs.fetch(:chdir)
      assert_equal true, kwargs.fetch(:pgroup)
      [@stdin, @stdout, Waiter.new]
    }) { yield }
    [payload, launch_root]
  end

  def with_conversion(endpoint: "ws://fake")
    bytes = pdf_bytes("body")
    processor = Object.new
    test = self
    check = ->(_kind, _html, options) {
      test.assert_equal endpoint, options["browserWsEndpoint"]
      bytes
    }
    processor.define_singleton_method(:convert, &check)
    Grover::Processor.stub(:new, ->(*) { processor }) { yield }
  end

  def test_batch_launch_uses_native_global_and_caller_options
    Grover.configuration.options = {executable_path: "/global/chrome", launch_args: '["--global"]', launch_timeout: "1234", root_path: "/global/root", debug: {devtools: true}}
    payload, root = capture_launch do
      ParademPdf::Document.browser(options: {launch_timeout: "4321"}) { |_| }
    end
    assert_equal "/global/chrome", payload["executablePath"]
    assert_equal ["--global"], payload["args"]
    assert_equal 4321, payload["timeout"]
    assert_equal true, payload["devtools"]
    assert_equal "/global/root", root
  end

  def test_document_launch_uses_body_metadata_with_native_coercion
    Grover.configuration.options = {executable_path: "/global/chrome", launch_timeout: "1234"}
    html = '<meta name="grover-executable_path" content="/meta/chrome"><meta name="grover-launch_timeout" content="4321"><meta name="grover-launch_args" content=\'["--meta"]\'><body>body</body>'
    payload, = capture_launch do
      with_conversion do
        ParademPdf::Document.new(doc_type: "test", body_html: html, origin: "https://example.test", locale: "en").to_pdf
      end
    end
    assert_equal "/meta/chrome", payload["executablePath"]
    assert_equal ["--meta"], payload["args"]
    assert_equal 4321, payload["timeout"]
  end

  def test_global_unsafe_flags_are_rejected_before_launch
    Grover.configuration.options = {launch_args: '["--no-sandbox"]'}
    Open3.stub(:popen2, ->(*, **) { flunk "Unsafe globals launched a process" }) do
      assert_raises(ArgumentError) { ParademPdf::Document.browser { |_| } }
    end
  end

  def test_metadata_unsafe_flags_are_rejected_before_launch
    html = '<meta name="grover-launch_args" content=\'["--disable-web-security"]\'>'
    Open3.stub(:popen2, ->(*, **) { flunk "Unsafe metadata launched a process" }) do
      assert_raises(ArgumentError) do
        ParademPdf::Document.new(doc_type: "test", body_html: html, origin: "https://example.test", locale: "en").to_pdf
      end
    end
  end

  def test_native_endpoint_from_globals_skips_managed_launch
    Grover.configuration.options = {browser_ws_endpoint: "ws://global"}
    ParademPdf::Browser.stub(:open, ->(**) { flunk "External endpoint launched a browser" }) do
      with_conversion(endpoint: "ws://global") do
        ParademPdf::Document.new(doc_type: "test", body_html: "body", origin: "https://example.test", locale: "en").to_pdf
      end
    end
  end

  def test_native_endpoint_from_metadata_skips_managed_launch
    html = '<meta name="grover-browser_ws_endpoint" content="ws://metadata"><body>body</body>'
    ParademPdf::Browser.stub(:open, ->(**) { flunk "External metadata endpoint launched a browser" }) do
      with_conversion(endpoint: "ws://metadata") do
        ParademPdf::Document.new(doc_type: "test", body_html: html, origin: "https://example.test", locale: "en").to_pdf
      end
    end
  end

  def test_nonpositive_native_launch_timeout_is_rejected
    [0, -1, "not-a-duration", false].each do |value|
      Open3.stub(:popen2, ->(*, **) { flunk "Unbounded native timeout launched a process" }) do
        assert_raises(ArgumentError) { ParademPdf::Browser.open(options: {launch_timeout: value}) }
      end
    end
  end

  def test_unsupported_raw_camel_launch_args_are_not_silently_ignored
    Grover.configuration.options = {launchArgs: ["--no-sandbox"]}
    Open3.stub(:popen2, ->(*, **) { flunk "Unsupported unsafe arguments were silently stripped" }) do
      assert_raises(ArgumentError) { ParademPdf::Browser.open }
    end
  end

  def test_safe_raw_camel_launch_args_are_rejected_with_the_canonical_key_message
    Grover.configuration.options = {launchArgs: ["--lang=en"]}
    Open3.stub(:popen2, ->(*, **) { flunk "Unsupported raw camel arguments were silently stripped" }) do
      error = assert_raises(ArgumentError) { ParademPdf::Browser.open }
      assert_match(/must use launch_args/, error.message)
    end
  end

  def test_reap_between_grace_and_signal_is_not_signaled
    waiter = Waiter.new(results: [false, true, true])
    without_signals do
      assert_raises(ParademPdf::BrowserError) { browser(waiter).close }
    end
    assert_empty @signals
  end

  def test_launch_reader_failure_closes_descriptors_and_keeps_original_exception
    original = IOError.new("endpoint read failed")
    fake_launch(Waiter.new) do
      ParademPdf::Browser.stub(:read_endpoint, ->(*) { raise original }) do
        assert_same original, assert_raises(IOError) { ParademPdf::Browser.open }
      end
    end
    assert @stdin.closed?
    assert @stdout.closed?
  end

  def test_interrupted_launch_still_closes_descriptors
    fake_launch(Waiter.new) do
      ParademPdf::Browser.stub(:read_endpoint, ->(*) { raise Interrupt }) do
        assert_raises(Interrupt) { ParademPdf::Browser.open }
      end
    end
    assert @stdin.closed?
    assert @stdout.closed?
  end

  def test_signal_permission_failure_is_reported_with_its_cause
    original = Errno::EPERM.new("owned launcher group")
    waiter = Waiter.new(results: [false, false])
    Process.stub(:kill, ->(*) { raise original }) do
      failure = assert_raises(ParademPdf::BrowserError) { browser(waiter).close }
      assert_same original, failure.cause
    end
    assert @stdin.closed?
    assert @stdout.closed?
  end

  def test_failed_launch_forced_cleanup_keeps_endpoint_failure_as_cause
    waiter = Waiter.new(results: [false, false, true])
    @stdout_writer.close
    without_signals do
      fake_launch(waiter) do
        failure = assert_raises(ParademPdf::BrowserError) { ParademPdf::Browser.open(timeout: 0.01) }
        assert_match(/forced cleanup/, failure.message)
        assert_match(/WebSocket endpoint/, failure.cause.message)
      end
    end
    assert_equal [["TERM", -waiter.pid]], @signals
    assert @stdout.closed?
  end
end
