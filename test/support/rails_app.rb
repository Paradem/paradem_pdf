require "test_helper"

module RailsSubprocess
  def run_rails_test(file)
    skip "Optional Rails integration requires the actionpack compatibility bundle" unless Gem::Specification.find_all_by_name("actionpack").any?
    output, errors, status = Open3.capture3({"PARADEM_PDF_RAILS_SUBPROCESS" => "1"},
      RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-I", File.expand_path("..", __dir__), file)
    assert status.success?, "#{output}\n#{errors}"
    assert_match(/0 failures, 0 errors, 0 skips/, output)
  end
end

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] == "1"
  require "tmpdir"
  require "fileutils"
  require "rails"
  require "action_controller/railtie"
  require "active_support/cache/file_store"
  require "paradem_pdf"
  require "support/pdf_helpers"

  module PdfRailsFixture
    CACHE_DIRECTORY = Dir.mktmpdir("paradem-pdf-rails-")
    at_exit { FileUtils.remove_entry(CACHE_DIRECTORY) }

    class Application < ::Rails::Application
      config.eager_load = false
      config.secret_key_base = "fixture-only-secret"
      config.logger = Logger.new(nil)
      config.cache_store = :file_store, CACHE_DIRECTORY
      config.hosts = ["reports.example.test"]
    end
    Application.initialize!

    module ReportHelper
      def report_label(value)
        "app helper: #{value}"
      end
    end

    class ReportsController < ActionController::Base
      append_view_path File.expand_path("rails_views", __dir__)
      helper ReportHelper
    end

    class AlternateController < ReportsController
      helper_method :renderer_name

      def renderer_name
        "alternate renderer"
      end
    end
  end
end
