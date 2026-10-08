require "test_helper"
require "paradem_pdf"
require "json"

class ReadinessScriptTest < Minitest::Test
  def test_timeout_rejects_javascript_timer_overflow_before_rendering
    [2**31, 2**32, 10**100].each do |timeout|
      error = assert_raises(ArgumentError) do
        ParademPdf::GroverRenderer.new(html: "body", origin: "https://example.test/",
          options: {}, margins: {}, readiness_timeout: timeout)
      end
      assert_includes error.message, "2147483647"
    end
    renderer = ParademPdf::GroverRenderer.new(html: "body", origin: "https://example.test/",
      options: {}, margins: {}, readiness_timeout: 2**31 - 1)
    assert_includes renderer.browser_options.fetch("executeScript"), "2147483647"
  end

  def run_script(scenario, timeout: 1000)
    script = ParademPdf::GroverRenderer.new(html: "body", origin: "https://example.test/",
      options: {}, margins: {}, readiness_timeout: timeout).browser_options.fetch("executeScript")
    # Run the actual hook with a controlled DOM, without launching a browser.
    source = <<~JS
      const {script, scenario} = JSON.parse(require('fs').readFileSync(0, 'utf8'));
      let active = 0, decoded = 0, layout = false, fontWaited = false;
      const nativeSet = global.setTimeout, nativeClear = global.clearTimeout;
      global.setTimeout = (fn, ms) => { active++; return nativeSet(fn, ms); };
      global.clearTimeout = id => { active--; nativeClear(id); };
      const image = {
        loading: 'lazy', currentSrc: 'fixture.png', naturalWidth: scenario === 'zero-width' ? 0 : 12,
        decode: async () => {
          decoded++;
          if (scenario === 'image-error') throw Error('corrupt');
          if (scenario === 'image-timeout') await new Promise(() => {});
        }
      };
      const fonts = [{status: scenario === 'font-error' ? 'error' : 'loaded'}, {status: 'unloaded'}];
      Object.defineProperty(fonts, 'ready', {get() {
        if (!layout) throw Error('fonts awaited before layout');
        fontWaited = true;
        return scenario === 'font-timeout' ? new Promise(() => {}) : Promise.resolve(fonts);
      }});
      global.document = {images: [image], fonts, body: {get offsetHeight() {layout = true; return 12;}}};
      (async () => {
        let error = null;
        try { await require('vm').runInThisContext(script); } catch (e) { error = e.message; }
        console.log(JSON.stringify({error, active, decoded, layout, fontWaited, loading: image.loading}));
      })();
    JS
    out, err, status = Open3.capture3("node", "-e", source, stdin_data: JSON.generate(script: script, scenario: scenario))
    assert status.success?, err
    JSON.parse(out)
  end

  def test_promotes_and_decodes_images_and_waits_for_fonts_after_layout
    result = run_script("ready")
    assert_nil result["error"]
    assert_equal "eager", result["loading"]
    assert_equal 1, result["decoded"]
    assert result["layout"]
    assert result["fontWaited"]
    assert_equal 0, result["active"]
  end

  def test_rejects_failed_images_and_fonts_and_clears_timer
    {"image-error" => "PDF image failed", "zero-width" => "PDF image failed",
     "font-error" => "PDF font failed"}.each do |scenario, message|
      result = run_script(scenario)
      assert_includes result["error"], message
      assert_equal 0, result["active"]
    end
  end

  def test_resource_deadline_rejects_and_clears_timer
    ["image-timeout", "font-timeout"].each do |scenario|
      result = run_script(scenario, timeout: 10)
      assert_includes result["error"], "PDF readiness timeout"
      assert_equal 0, result["active"]
    end
  end
end
