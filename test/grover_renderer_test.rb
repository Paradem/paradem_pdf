require "test_helper"
require "paradem_pdf"
require "support/pdf_helpers"

class GroverRendererTest < Minitest::Test
  include PdfHelpers

  def renderer(**args)
    assert ParademPdf.const_defined?(:GroverRenderer), "Native rendering adapter is missing"
    ParademPdf::GroverRenderer.new(html: "<html>body</html>", origin: "https://example.test", options: {}, margins: {}, **args)
  end

  def setup
    @configuration = Grover.configuration
    @saved_options = @configuration.options
    @saved_file = @configuration.allow_file_uris
    @saved_network = @configuration.allow_local_network_access
    @configuration.options = {}
  end

  def teardown
    @configuration.options = @saved_options
    @configuration.allow_file_uris = @saved_file
    @configuration.allow_local_network_access = @saved_network
  end

  def test_normalizes_origin_and_preprocesses_only_native_asset_paths
    r = renderer(html: '<img src="/logo"><img src="//cdn.test/font"><img src="relative.png">', origin: "https://example.test/path///")
    inputs = r.fingerprint_inputs
    assert_equal "https://example.test/path/", inputs["origin"]
    assert_includes inputs["html"], 'src="https://example.test/path/logo"'
    assert_includes inputs["html"], 'src="https://cdn.test/font"'
    assert_includes inputs["html"], 'src="relative.png"'
  end

  def test_rejects_invalid_origins_before_conversion
    [nil, "", "relative", "file:///tmp/a", "https://", "https://user:pass@example.test", "https://example.test?x", "https://example.test#x", "https://example.test:0", "https://example.test:65536"].each do |origin|
      assert_raises(ArgumentError) { renderer(origin: origin) }
    end
  end

  def test_preserves_failure_policy_despite_options_or_html_metadata
    [{display_url: "https://other.test/"}, {displayUrl: "https://other.test/"},
      {raise_on_request_failure: false}, {raiseOnRequestFailure: false}].each do |options|
      assert_raises(ArgumentError) { renderer(options: options) }
    end
    ['<meta name="grover-display_url" content="https://other.test/">',
      '<meta name="grover-raise_on_request_failure" content="false">'].each do |html|
      assert_raises(ArgumentError) { renderer(html: html) }
    end
  end

  def test_rejects_conflicting_aliases_even_when_another_alias_is_safe
    [{display_url: "https://other.test/", displayUrl: "https://example.test/"},
      {raise_on_request_failure: false, raiseOnRequestFailure: true},
      {"raise_on_request_failure" => false, :raise_on_request_failure => true}].each do |options|
      assert_raises(ArgumentError) { renderer(options: options) }
    end
  end

  def test_accepts_native_control_names_and_native_failure_coercion
    inputs = renderer(options: {displayUrl: "https://example.test/", raiseOnRequestFailure: "true"}).fingerprint_inputs
    assert_equal "https://example.test/", inputs["options"]["displayUrl"]
    assert_equal true, inputs["options"]["raiseOnRequestFailure"]
    assert_raises(ArgumentError) { renderer(options: {raise_on_request_failure: "false"}) }
  end

  def test_invalid_margin_option_is_an_api_error
    assert_raises(ArgumentError) { renderer(options: {margin: "invalid"}) }
  end

  def test_captured_inputs_are_not_mutated_and_each_conversion_has_a_fresh_processor
    processors = []
    factory = Grover::Processor.method(:new)
    r = renderer(options: {timeout: "1234"})
    inputs = r.fingerprint_inputs
    inputs["options"]["timeout"] = 0
    Grover::Processor.stub(:new, ->(root) {
      processor = factory.call(root)
      processors << processor
      processor.define_singleton_method(:convert) do |kind, html, options|
        raise "Wrong captured timeout" unless options["timeout"] == 1234
        options["timeout"] = 0
        "bytes"
      end
      processor
    }) do
      2.times { assert_equal "bytes", r.to_pdf }
    end
    refute_same processors[0], processors[1]
    assert_equal 1234, r.fingerprint_inputs["options"]["timeout"]
  end

  def test_captures_options_before_caller_mutation
    margin = +"5mm"
    root = +Dir.pwd
    r = renderer(margins: {top: margin}, options: {root_path: root})
    margin.replace("50mm")
    root.replace("/different")
    inputs = r.fingerprint_inputs
    assert_equal "5mm", inputs["options"]["margin"]["top"]
    assert_equal Dir.pwd, inputs["root_path"]
  end

  def test_selected_margins_override_native_global_and_caller_merge_but_not_metadata
    @configuration.options = {margin: {top: "1mm", left: "2mm"}}
    r = renderer(options: {margin: {top: "3mm", right: "4mm"}}, margins: {top: "5mm"})
    assert_equal({"top" => "5mm", "left" => "2mm", "right" => "4mm"}, r.fingerprint_inputs["options"]["margin"])
    assert_raises(ArgumentError) { renderer(html: '<meta name="grover-margin-top" content="6mm">', margins: {top: "5mm"}) }
    assert_equal "5mm", renderer(html: '<meta name="grover-margin-top" content="5mm">', margins: {top: "5mm"}).fingerprint_inputs["options"]["margin"]["top"]
  end

  def test_captures_native_metadata_coercion_and_dispatches_exact_fingerprint
    r = renderer(html: '<meta name="grover-format" content="A4"><meta name="grover-landscape" content="true"><meta name="grover-timeout" content="4321">', options: {root_path: Dir.pwd, path: "native.pdf"})
    inputs = r.fingerprint_inputs
    assert_equal "A4", inputs["options"]["format"]
    assert_equal true, inputs["options"]["landscape"]
    assert_equal 4321, inputs["options"]["timeout"]
    assert_equal "native.pdf", inputs["options"]["path"]
    assert_equal Dir.pwd, inputs["root_path"]
    convert_using(->(kind, html, options, root) {
      assert_equal :pdf, kind
      assert_equal inputs["html"], html
      assert_equal inputs["options"], options
      assert_equal inputs["root_path"], root
      "pdf bytes"
    }) { assert_equal "pdf bytes", r.to_pdf }
  end

  def test_captures_native_file_network_and_javascript_controls
    @configuration.allow_file_uris = true
    @configuration.allow_local_network_access = true
    r = nil
    _stdout, stderr = capture_io do
      r = renderer(options: {javascript_enabled: "false", execute_script: "alert(1)", wait_for_function: "ready"})
    end
    options = r.fingerprint_inputs["options"]
    assert_equal false, options["javaScriptEnabled"]
    refute options.key?("executeScript")
    refute options.key?("waitForFunction")
    assert_includes stderr, "has been disabled"
    assert_equal true, options["allowFileUri"]
    assert_equal true, options["allowLocalNetworkAccess"]
    @configuration.allow_file_uris = false
    @configuration.allow_local_network_access = false
    convert_using(->(_kind, _html, effective, *) {
      assert_equal options, effective
      "bytes"
    }) { r.to_pdf }
    refute_equal options, renderer.fingerprint_inputs["options"]
  end

  def test_to_pdf_passes_browser_endpoint_to_convert_only
    endpoint = "ws://127.0.0.1:1/devtools/browser/x"
    r = renderer
    convert_using(->(_kind, _html, options, *) {
      assert_equal endpoint, options["browserWsEndpoint"]
      "bytes"
    }) { assert_equal "bytes", r.to_pdf(browser_endpoint: endpoint) }
  end

  def test_to_pdf_without_endpoint_omits_browser_ws_endpoint
    r = renderer
    convert_using(->(_kind, _html, options, *) {
      refute options.key?("browserWsEndpoint")
      "bytes"
    }) { assert_equal "bytes", r.to_pdf }
  end

  def test_browser_endpoint_never_enters_fingerprint_inputs
    r = renderer
    convert_using(->(_kind, _html, _options, *) { "bytes" }) do
      r.to_pdf(browser_endpoint: "ws://127.0.0.1:1/devtools/browser/x")
    end
    inputs = r.fingerprint_inputs
    refute inputs.key?("browserWsEndpoint")
    refute inputs["options"].key?("browserWsEndpoint")
  end

  def test_root_path_reader_returns_resolved_root_path
    assert_equal Dir.pwd, renderer.root_path
    assert_equal "/custom/root", renderer(options: {root_path: "/custom/root"}).root_path
  end

  def test_browser_options_reuse_captured_native_options_without_later_globals
    @configuration.options = {executable_path: "/global/chrome", launch_args: '["--global"]'}
    r = renderer(html: '<meta name="grover-launch_timeout" content="4321">')
    @configuration.options = {executable_path: "/later/chrome"}
    launch = r.browser_options
    assert_equal "/global/chrome", launch["executablePath"]
    assert_equal ["--global"], launch["launchArgs"]
    assert_equal 4321, launch["launchTimeout"]
    launch["launchArgs"] << "--changed"
    assert_equal ["--global"], r.browser_options["launchArgs"]
  end

  def test_batch_normalization_uses_native_coercion_and_global_root
    @configuration.options = {root_path: "/global/root", launch_args: '["--global"]', launch_timeout: "1234"}
    options, root = ParademPdf::GroverRenderer.normalize_browser_options(options: {launch_timeout: "4321"})
    assert_equal "/global/root", root
    assert_equal ["--global"], options["launchArgs"]
    assert_equal 4321, options["launchTimeout"]
  end

  def test_global_and_metadata_endpoints_are_conversion_only
    ["global", "metadata"].each do |source|
      @configuration.options = (source == "global") ? {browser_ws_endpoint: "ws://global"} : {}
      html = (source == "metadata") ? '<meta name="grover-browser_ws_endpoint" content="ws://metadata"><body>body</body>' : "body"
      r = renderer(html: html)
      assert_equal "ws://#{source}", r.browser_endpoint
      refute_includes r.fingerprint_inputs.to_s, "ws://#{source}"
      refute r.browser_options.key?("browserWsEndpoint")
      convert_using(->(_kind, _html, effective, *) {
        assert_equal "ws://#{source}", effective["browserWsEndpoint"]
        "bytes"
      }) { r.to_pdf }
    end
  end
end
