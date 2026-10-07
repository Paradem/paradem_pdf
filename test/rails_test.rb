require "support/rails_app"

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] == "1"
  class RailsTest < Minitest::Test
    include PdfHelpers

    def setup
      assert File.file?(File.expand_path("../lib/paradem_pdf/rails.rb", __dir__)), "Optional Rails entry point is missing"
      require "paradem_pdf/rails"
    end

    def document_options
      {doc_type: "report", body_html: "body", origin: "https://reports.example.test/", locale: "en",
       cache_namespace: "fixture", freshness: "snapshot-1", assets_version: "assets-1", expires_in: 60}
    end

    def test_default_explicit_and_nil_cache_and_all_options_are_forwarded
      received = []
      marker = Object.new
      explicit = Object.new
      options = document_options.merge(header: ->(**) { "header" }, footer: nil,
        options: {format: "Letter", print_background: false}, body_margins: {top: "12px"},
        header_margins: {left: "1px"}, footer_margins: {bottom: "2px"})
      ParademPdf::Document.stub(:new, ->(**keywords) {
        received << keywords
        marker
      }) do
        assert_same marker, ParademPdf::Rails.document(**options)
        assert_same marker, ParademPdf::Rails.document(**options, cache: explicit)
        assert_same marker, ParademPdf::Rails.document(**options, cache: nil)
      end
      assert_equal [options.merge(cache: ::Rails.cache), options.merge(cache: explicit), options.merge(cache: nil)], received
      assert_instance_of ActiveSupport::Cache::FileStore, ::Rails.cache
    end

    def test_file_store_instances_share_bytes_and_expire_without_clearing
      Dir.mktmpdir("paradem-pdf-filestore-") do |directory|
        first = ActiveSupport::Cache::FileStore.new(directory)
        second = ActiveSupport::Cache::FileStore.new(directory)
        bytes = pdf_bytes("cached report")
        assert first.write("completed", bytes, expires_in: 60)
        assert_equal bytes, second.read("completed")
        assert second.write("expired", bytes, expires_in: 0.01)
        sleep 0.03
        assert_nil first.read("expired")
        assert_equal bytes, first.read("completed")
      end
    end

    def test_app_rendered_letter_pixels_nil_decorations_and_options_do_not_bleed
      adapter = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::ReportsController.renderer, layout: false)
      body = adapter.render(template: "reports/standalone", locals: {title: "Print"}, assigns: {account: "Account"})
      calls = []
      convert_using(->(_kind, html, options, _root) {
        calls << [html, options]
        pdf_bytes("body", box: options["landscape"] ? LANDSCAPE : LETTER)
      }) do
        first = ParademPdf::Rails.document(**document_options.merge(body_html: body, cache: nil,
          options: {format: "Letter", print_background: false}, body_margins: {top: "12px", bottom: "18px"}, header: nil, footer: nil))
        second = ParademPdf::Rails.document(**document_options.merge(cache: nil))
        assert_equal LETTER, CombinePDF.parse(first.to_pdf).pages.first[:MediaBox]
        second.to_pdf
      end
      assert_equal 2, calls.length
      assert_equal "Letter", calls.first.last["format"]
      assert_equal false, calls.first.last["printBackground"]
      assert_equal({"top" => "12px", "bottom" => "18px"}, calls.first.last["margin"])
      refute calls.last.last.key?("format")
      refute calls.last.last.key?("printBackground")
      assert_equal({}, calls.last.last["margin"])
    end

    def test_matching_landscape_app_body_and_decoration
      body_renderer = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::ReportsController.renderer, layout: "reports")
      decoration_renderer = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::ReportsController.renderer, layout: false)
      body = body_renderer.render(template: "reports/body", locals: {title: "Report", account: "local"}, assigns: {account: "assigned", language: "en"})
      footer = ->(page:, total_pages:) {
        decoration_renderer.render(template: "reports/decoration", locals: {title: "Footer", page: page, total_pages: total_pages}, assigns: {account: "assigned"})
      }
      calls = []
      convert_using(->(_kind, html, options, _root) {
        calls << [html, options]
        pdf_bytes(html.include?("Footer") ? "Footer 1/1" : "Report", box: options["landscape"] ? LANDSCAPE : LETTER)
      }) do
        bytes = ParademPdf::Rails.document(**document_options.merge(body_html: body, footer: footer, cache: nil,
          options: {format: "Letter", landscape: true})).to_pdf
        page = CombinePDF.parse(bytes).pages.first
        assert_equal LANDSCAPE, page[:MediaBox]
        assert_includes page_text(page), "Footer 1/1"
      end
      assert_equal 2, calls.length
      assert calls.all? { |_, options| options["landscape"] == true }
      assert_includes calls.last.first, "app helper: Footer 1/1 | assigned"
    end
  end
else
  class RailsSubprocessTest < Minitest::Test
    include RailsSubprocess

    def test_optional_cache_and_document_in_isolated_process
      run_rails_test(__FILE__)
    end
  end
end
