require "support/rails_app"
require "tmpdir"

module PrecacheReloadFixture
  SOURCE = <<~RUBY
    class ReloadGuidePdf
      include ParademPdf::Rails::Precacheable

      def self.precache_entries
        [{label: "guide-v1"}]
      end

      def to_pdf(label:, browser:, require_cache_write:)
        PdfReloadProbe::ENTERED << [Thread.current, self.class.object_id, ParademPdf.configuration.cache_version, label]
        Timeout.timeout(10) { PdfReloadProbe::RELEASE.pop }
        ParademPdf::Document.new(doc_type: "reload-guide", locale: "en",
          body_html: label, cache_key: label).to_pdf(browser: browser, require_cache_write: require_cache_write)
      end
    end
  RUBY
end

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] != "1"
  class RailsPrecacheReloadSubprocessTest < Minitest::Test
    include RailsSubprocess

    def test_pending_pass_resolves_reloaded_classes_without_replacing_scheduler_state
      Dir.mktmpdir("precache-reload-") do |directory|
        File.write(File.join(directory, "reload_guide_pdf.rb"), PrecacheReloadFixture::SOURCE)
        run_rails_test(__FILE__, env: {"PARADEM_PDF_RELOAD_DIRECTORY" => directory})
      end
    end
  end
else
  require "paradem_pdf/rails"
  require "support/cache_store"
  require "timeout"

  module PdfReloadProbe
    ENTERED = Queue.new
    RELEASE = Queue.new
  end

  class RailsPrecacheReloadTest < Minitest::Test
    include PdfHelpers

    def test_pending_pass_resolves_reloaded_classes_without_replacing_scheduler_state
      assert Object.autoload?(:ReloadGuidePdf), "Fixture must not have been loaded before warming"
      ParademPdf.configure do |config|
        config.precache_document_classes = ["ReloadGuidePdf"]
        config.origin = "https://reports.example.test/"
        config.cache_namespace = "reload-test"
        config.cache = TestCacheStore.new
      end
      app = ::Rails.application
      generation = 0
      app.reloader.to_prepare do
        generation += 1
        ParademPdf.configuration.cache_version = "generation-#{generation}"
      end
      app.reloader.check = -> { true }
      state = ParademPdf::Rails::PrecacheScheduler.instance_variable_get(:@state)
      worker = nil
      boundaries = Queue.new
      wrap = app.reloader.method(:wrap)
      app.reloader.stub(:wrap, ->(&block) {
        boundaries << true
        wrap.call(&block)
      }) do
        convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
          Timeout.timeout(15) do
            app.executor.wrap { assert_equal :started, ParademPdf::Rails.precache_later }
            first = PdfReloadProbe::ENTERED.pop
            worker = first.first
            path = File.join(ENV.fetch("PARADEM_PDF_RELOAD_DIRECTORY"), "reload_guide_pdf.rb")
            File.write(path, PrecacheReloadFixture::SOURCE.sub("guide-v1", "guide-v2"))
            10.times { assert_equal :pending, ParademPdf::Rails.precache_later(reason: :save) }
            PdfReloadProbe::RELEASE << true
            second = PdfReloadProbe::ENTERED.pop
            assert_equal worker, second.first
            refute_equal first[1], second[1]
            refute_equal first[2], second[2]
            assert_equal ["guide-v1", "guide-v2"], [first[3], second[3]]
            assert_same state, ParademPdf::Rails::PrecacheScheduler.instance_variable_get(:@state)
            PdfReloadProbe::RELEASE << true
            assert_equal worker, worker.join(5)
            assert_equal [false, false, nil], state.values_at(:running, :pending, :owner)
            assert_equal 2, boundaries.length
            assert_empty PdfReloadProbe::ENTERED
          end
        end
      end
    ensure
      worker&.kill if worker&.alive?
      worker&.join(5)
    end
  end
end
