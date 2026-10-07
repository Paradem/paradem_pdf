require "support/rails_app"

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] == "1"
  class RailsRendererTest < Minitest::Test
    def setup
      assert File.file?(File.expand_path("../lib/paradem_pdf/rails.rb", __dir__)), "Optional Rails entry point is missing"
      require "paradem_pdf/rails"
    end

    def test_named_layout_helpers_assigns_and_locals
      adapter = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::ReportsController.renderer, layout: "reports")
      before = I18n.locale
      html = adapter.render(template: "reports/body", locals: {title: "Invoice", account: "local account"},
        assigns: {language: "ar", account: "assigned account"})
      assert_includes html, 'data-layout="reports"'
      assert_includes html, 'lang="ar"'
      assert_includes html, "app helper: Invoice | assigned: assigned account | local: local account"
      assert_equal before, I18n.locale
    end

    def test_layout_false_and_selected_renderer
      adapter = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::ReportsController.renderer, layout: false)
      html = adapter.render(template: "reports/standalone", locals: {title: "Print"}, assigns: {account: "Account"})
      assert_includes html, "<!DOCTYPE html>"
      assert_includes html, "app helper: Print | Account"
      refute_includes html, "data-layout"
      alternate = ParademPdf::RailsRenderer.new(renderer: PdfRailsFixture::AlternateController.renderer, layout: "alternative")
      html = alternate.render(template: "reports/alternate")
      assert_includes html, 'data-layout="alternative"'
      assert_includes html, "alternate renderer"
    end

    def test_forwards_keywords_without_changing_them
      calls = []
      supplied = Object.new
      supplied.define_singleton_method(:render) do |**options|
        calls << options
        "html"
      end
      adapter = ParademPdf::RailsRenderer.new(renderer: supplied, layout: false)
      locals = {title: "Title"}
      assigns = {language: "en"}
      assert_equal "html", adapter.render(template: "app/body", locals: locals, assigns: assigns)
      assert_equal [{template: "app/body", layout: false, locals: locals, assigns: assigns}], calls
      assert_same locals, calls.first[:locals]
      assert_same assigns, calls.first[:assigns]
    end
  end
else
  class RailsRendererSubprocessTest < Minitest::Test
    include RailsSubprocess

    def test_optional_renderer_in_isolated_process
      run_rails_test(__FILE__)
    end
  end
end
