require "test_helper"
require "paradem_pdf"
require "support/pdf_helpers"
require "support/cache_store"

class ConfigurationTest < Minitest::Test
  include PdfHelpers

  def setup
    ParademPdf.reset_configuration!
  end

  def teardown
    ParademPdf.reset_configuration!
  end

  def configure(store = TestCacheStore.new)
    ParademPdf.configure do |config|
      config.cache = store
      config.cache_namespace = "app"
      config.origin = "https://configured.example.test:8443/"
      config.options = {format: "Letter", emulate_media: "print"}
      config.cache_version = "content-schema-1"
      config.expires_in = 60
    end
    store
  end

  def document(**options)
    ParademPdf::Document.new(doc_type: "invoice", locale: "en", cache_key: ["content"],
      body_html: -> { "body" }, **options)
  end

  def test_defaults_and_configure
    assert_equal({}, ParademPdf.configuration.options)
    assert_nil ParademPdf.configuration.origin
    assert_nil ParademPdf.configuration.expires_in
    assert_nil ParademPdf.configuration.cache_version
    configure
    assert_equal "app", ParademPdf.configuration.cache_namespace
  end

  def test_precache_allowlist_defaults_and_reset_are_isolated
    config = ParademPdf.configuration
    assert_respond_to config, :precache_document_classes
    assert_equal [], config.precache_document_classes
    config.precache_document_classes << "FixtureGuidePdf"
    ParademPdf.reset_configuration!
    assert_equal [], ParademPdf.configuration.precache_document_classes
    assert_equal ["FixtureGuidePdf"], config.precache_document_classes
  end

  def test_completed_hit_never_resolves_body_or_footer_and_uses_configured_options
    store = configure
    body_calls = 0
    footer_calls = 0
    converted = []
    inputs = {body_html: -> {
      body_calls += 1
      "body"
    }, footer: ->(**) {
      footer_calls += 1
      "footer"
    }}
    convert_using(->(_kind, html, options, *) {
      converted << [html, options]
      pdf_bytes(html)
    }) do
      bytes = document(**inputs).to_pdf
      assert_equal bytes, document(**inputs).to_pdf
    end
    assert_equal 1, body_calls
    assert_equal 1, footer_calls
    assert_equal 2, store.writes.length
    assert converted.all? { |_, options| options["emulateMedia"] == "print" }
    assert converted.all? { |_, options| options["displayUrl"] == "https://configured.example.test:8443/" }
  end

  def test_explicit_nil_cache_and_expiry_override_defaults
    store = configure
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      document(cache: nil).to_pdf
      assert_empty store.writes
      document(expires_in: nil).to_pdf
      assert_nil store.writes.last.last
    end
  end

  def test_origin_override_and_configuration_are_captured_at_construction
    configure
    built = document(origin: "http://override.example.test:3004", options: {format: "A4"})
    ParademPdf.configuration.options[:format] = "A3"
    ParademPdf.configuration.origin = "https://changed.example.test/"
    options = nil
    convert_using(->(_kind, html, effective, *) {
      options = effective
      pdf_bytes(html)
    }) { built.to_pdf }
    assert_equal "A4", options["format"]
    assert_equal "http://override.example.test:3004/", options["displayUrl"]
  end

  def test_missing_and_invalid_origins_reject_before_rendering_or_cache
    store = configure
    [nil, "ftp://invalid/", "https://user:password@example.test/"].each do |origin|
      ParademPdf.configuration.origin = origin
      assert_raises(ArgumentError) { document(body_html: -> { flunk "Rendered invalid origin" }) }
    end
    assert_empty store.reads
  end

  def test_cache_version_change_invalidates_completed_and_overlay_cache
    configure
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      document(footer: ->(**) { "footer" }).to_pdf
      ParademPdf.configuration.cache_version = "content-schema-2"
      document(footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal 4, conversions.length
  end

  def test_cached_documents_require_declared_dependencies
    store = configure
    assert_raises(ArgumentError) { document(cache_key: nil) }
    assert_raises(ArgumentError) { document(cache_key: {symbol: "invalid"}) }
    assert_empty store.reads
  end

  def test_false_and_nil_cache_versions_override_configured_defaults
    configure
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      document.to_pdf
      2.times do
        document(cache_version: false).to_pdf
        document(cache_version: nil).to_pdf
      end
    end
    assert_equal 3, conversions.length
  end

  def test_body_callback_must_return_html_and_failures_are_not_cached
    store = configure
    assert_raises(ArgumentError) { document(body_html: -> {}).to_pdf }
    assert_empty store.writes
  end
end
