require "support/rails_app"

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] != "1"
  class RailsPrecacheSubprocessTest < Minitest::Test
    include RailsSubprocess

    def test_rails_precaching
      run_rails_test(__FILE__)
    end
  end
else
  require "paradem_pdf/rails"
  require "support/precache_documents"

  class FixtureUnconfiguredPdf
    def self.precache_entries
      raise "Unconfigured class was consulted"
    end
  end

  class FixtureMissingEntriesPdf
    include ParademPdf::Rails::Precacheable

    def to_pdf(**)
      raise "Should not render without entries"
    end
  end

  class FixtureMissingRenderPdf
    include ParademPdf::Rails::Precacheable

    def self.precache_entries
      [{label: "private entry"}]
    end
  end

  class RailsPrecacheTest < Minitest::Test
    include PdfHelpers

    def setup
      ParademPdf.reset_configuration!
      ParademPdf.configure do |config|
        config.origin = "https://reports.example.test/"
        config.cache = TestCacheStore.new
        config.cache_namespace = "precache-test"
      end
      [FixtureGuidePdf, FixtureReceiptPdf].each do |klass|
        klass.calls = []
        klass.document_options = {}
      end
      FixtureGuidePdf.entries = [{label: "guide"}, {label: "second guide"}]
      FixtureReceiptPdf.entries = [{label: "receipt"}]
    end

    def teardown
      ParademPdf.reset_configuration!
    end

    def test_two_opted_in_types_share_one_browser_and_normal_render_path
      assert_respond_to ParademPdf::Rails, :precache
      ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
      opened = []
      conversions = []
      convert_using(->(_kind, html, *) {
        conversions << html
        pdf_bytes(html)
      }, browser: -> {
        opened << FakeBrowser.new
        opened.last
      }) do
        result = ParademPdf::Rails.precache
        assert_equal [3, 3, 0], [result.attempted, result.succeeded, result.failed]
      end
      assert_equal ["guide", "second guide", "receipt"], conversions
      assert_equal 1, opened.length
      assert opened.first.closed?
      calls = FixtureGuidePdf.calls + FixtureReceiptPdf.calls
      assert_equal conversions, calls.map(&:first)
      assert calls.all? { |_, browser, strict| browser.equal?(opened.first) && strict == true }
      assert_equal 3, ParademPdf.configuration.cache.writes.length
    end

    def test_empty_opt_in_or_entries_launches_nothing
      [[], %w[FixtureGuidePdf FixtureReceiptPdf]].each do |names|
        ParademPdf.configuration.precache_document_classes = names
        FixtureGuidePdf.entries = []
        FixtureReceiptPdf.entries = []
        ParademPdf::Browser.stub(:open, ->(**) { flunk "Opened an empty batch browser" }) do
          [nil, []].each do |selection|
            result = ParademPdf::Rails.precache(documents: selection)
            assert_equal [0, 0, 0], [result.attempted, result.succeeded, result.failed]
          end
        end
      end
      assert_empty FixtureGuidePdf.calls
      assert_empty FixtureReceiptPdf.calls
    end

    def test_selected_names_must_be_configured
      ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
      convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
        result = ParademPdf::Rails.precache(documents: ["FixtureReceiptPdf"])
        assert_equal [1, 1, 0], [result.attempted, result.succeeded, result.failed]
      end
      assert_empty FixtureGuidePdf.calls
      assert_equal ["receipt"], FixtureReceiptPdf.calls.map(&:first)
      assert defined?(ParademPdf::Rails::Precache::InfrastructureError), "Missing normalized infrastructure error"
      ParademPdf::Browser.stub(:open, ->(**) { flunk "Opened browser for unknown selection" }) do
        error = assert_raises(ParademPdf::Rails::Precache::InfrastructureError) do
          ParademPdf::Rails.precache(documents: ["FixtureUnconfiguredPdf"])
        end
        assert_nil error.cause
        refute_match(/Unconfigured class was consulted/, error.message)
      end
    end

    def test_invalid_configuration_and_enumeration_fail_before_browser
      cases = [nil, "FixtureGuidePdf", [FixtureGuidePdf], [""], ["FixtureGuidePdf\n"],
        ["MissingPrivateConstant"], ["PdfRailsFixture"], ["FixtureUnconfiguredPdf"],
        ["FixtureMissingEntriesPdf"], ["FixtureMissingRenderPdf"]]
      ParademPdf::Browser.stub(:open, ->(**) { flunk "Browser opened before complete validation" }) do
        cases.each do |configured|
          ParademPdf.configuration.precache_document_classes = configured
          assert_infrastructure { ParademPdf::Rails.precache }
        end
        ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
        [nil, {}, [nil], ["private entry"], [{"label" => "private entry"}],
          [{browser: "private endpoint"}], [{require_cache_write: false}]].each do |entries|
          FixtureReceiptPdf.entries = entries
          assert_infrastructure { ParademPdf::Rails.precache }
          assert_empty FixtureGuidePdf.calls
        end
        FixtureReceiptPdf.stub(:precache_entries, -> { raise "private enumeration" }) do
          assert_infrastructure { ParademPdf::Rails.precache }
        end
      end
      assert_equal false, FixtureMissingEntriesPdf.precache_affected_by?(:anything, {})
      assert_raises(ParademPdf::PrecacheConfigurationError) { FixtureMissingEntriesPdf.precache_entries }
    end

    def assert_infrastructure
      error = assert_raises(ParademPdf::Rails::Precache::InfrastructureError) { yield }
      assert_nil error.cause
      assert_match(/\Aparadem-pdf-precache infrastructure error=[\w:]+\z/, error.message)
      refute_match(/private|Should not|Unconfigured/, error.message)
      error
    end

    def test_instance_or_render_failure_does_not_skip_later_entries_or_types
      ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
      FixtureGuidePdf.entries = [{label: "private construction"}, {label: "private conversion"}, {label: "later guide"}]
      output = StringIO.new
      warnings = []
      factory = FixtureGuidePdf.method(:new)
      instances = 0
      constructor = -> {
        instances += 1
        raise "private constructor message" if instances == 1
        factory.call
      }
      ::Rails.stub(:logger, Logger.new(output)) do
        FixtureGuidePdf.stub(:new, constructor) do
          convert_using(->(_kind, html, *) {
            raise "private renderer message" if html == "private conversion"
            pdf_bytes(html)
          }) do
            result = ParademPdf::Rails.precache(on_warning: ->(warning) { warnings << warning })
            assert_equal [4, 2, 2], [result.attempted, result.succeeded, result.failed]
          end
        end
      end
      assert_equal ["later guide", "receipt"], ParademPdf.configuration.cache.writes.map { |write| page_text(CombinePDF.parse(write[1]).pages.first).strip }
      assert_equal ["receipt"], FixtureReceiptPdf.calls.map(&:first)
      assert_equal ["paradem-pdf-precache failed document=FixtureGuidePdf entry=1 error=RuntimeError",
        "paradem-pdf-precache failed document=FixtureGuidePdf entry=2 error=RuntimeError"], warnings
      warnings.each { |warning| assert_equal 1, output.string.scan(warning).length }
      refute_match(/private/, output.string)
    rescue ParademPdf::Rails::Precache::InfrastructureError
      flunk "A document failure aborted the batch"
    end

    def test_effective_cache_and_versions_remain_caller_owned
      ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
      [nil, TestCacheStore.new].each do |global_store|
        ParademPdf.configuration.cache = global_store
        own_store = TestCacheStore.new
        FixtureGuidePdf.document_options = {cache: nil}
        FixtureReceiptPdf.document_options = {cache: own_store}
        convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
          [nil, false].each do |version|
            FixtureReceiptPdf.document_options[:cache_version] = version
            result = ParademPdf::Rails.precache
            assert_equal [3, 1, 2], [result.attempted, result.succeeded, result.failed]
          end
        end
        assert_equal 2, own_store.writes.length
        assert_empty global_store.writes if global_store
      end
    end

    def test_browser_and_reporting_failures_have_infrastructure_semantics
      ParademPdf.configuration.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
      ParademPdf::Browser.stub(:open, ->(**) { raise ParademPdf::BrowserError, "private launch" }) do
        assert_infrastructure { ParademPdf::Rails.precache }
      end
      [:endpoint, :close].each do |failure|
        browser = FakeBrowser.new
        original = browser.method(failure)
        browser.define_singleton_method(failure) do
          original.call
          raise ParademPdf::BrowserError, "private browser"
        end
        convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> { browser }) do
          assert_infrastructure { ParademPdf::Rails.precache }
        end
        assert browser.closed?
      end
      [RuntimeError, ParademPdf::BrowserError, ParademPdf::PrecacheConfigurationError].each do |type|
        browser = FakeBrowser.new
        FixtureGuidePdf.stub(:new, -> { raise type, "private HTML <secret>" }) do
          convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> { browser }) do
            if type == RuntimeError
              assert_infrastructure { ParademPdf::Rails.precache(on_warning: ->(_) { raise "private callback" }) }
              logger = Object.new
              logger.define_singleton_method(:warn) { |_| raise "private logger" }
              ::Rails.stub(:logger, logger) { assert_infrastructure { ParademPdf::Rails.precache } }
            else
              assert_infrastructure { ParademPdf::Rails.precache }
            end
          end
        end
        assert browser.closed?
      end
    end

    def test_warning_identifies_the_configured_name_not_a_class_alias_target
      ParademPdf.configuration.precache_document_classes = ["FixtureGuideAliasPdf"]
      warnings = []
      FixtureGuidePdf.stub(:new, -> { raise "private failure" }) do
        convert_using(->(*) { flunk "Rendered a construction failure" }) do
          result = ParademPdf::Rails.precache(on_warning: ->(warning) { warnings << warning })
          assert_equal [2, 0, 2], [result.attempted, result.succeeded, result.failed]
        end
      end
      assert_match(/document=FixtureGuideAliasPdf entry=1/, warnings.first)
    end

    def test_lifecycle_failures_are_normalized_at_the_public_boundary
      ::Rails.application.reloader.stub(:wrap, -> { raise "private lifecycle path" }) do
        assert_infrastructure { ParademPdf::Rails.precache }
      end
    end

    def test_configured_names_are_snapshotted_before_enumerating_entries
      names = ["FixtureGuidePdf"]
      ParademPdf.configuration.precache_document_classes = names
      entries = FixtureGuidePdf.method(:precache_entries)
      FixtureGuidePdf.stub(:precache_entries, -> {
        names << "FixtureReceiptPdf" if names.length == 1
        entries.call
      }) do
        convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
          assert_equal 2, ParademPdf::Rails.precache.attempted
          assert_equal 3, ParademPdf::Rails.precache.attempted
        end
      end
    end
  end
end
