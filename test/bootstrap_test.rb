require "test_helper"

class BootstrapTest < Minitest::Test
  include StandaloneRuby

  def test_core_loads_without_application_constants
    output, errors, status = run_ruby(<<~RUBY)
      require "paradem_pdf"
      abort "Application constant loaded" if [:Rails, :ApplicationController, :ActiveRecord].any? { |name| Object.const_defined?(name) }
      abort "Missing package version" unless ParademPdf::VERSION.is_a?(String) && !ParademPdf::VERSION.empty?
      puts "standalone"
    RUBY

    assert status.success?, errors
    assert_equal "standalone\n", output
  end

  def test_package_includes_native_worker_preload
    spec = Gem::Specification.load("paradem_pdf.gemspec")
    assert_includes spec.files, "lib/paradem_pdf/worker_context.cjs"
  end

  def test_package_declares_approved_mit_license
    spec = Gem::Specification.load("paradem_pdf.gemspec")
    assert_equal ["MIT"], spec.licenses
  end

  def test_package_includes_license_and_linked_technical_guides_without_test_artifacts
    spec = Gem::Specification.load("paradem_pdf.gemspec")
    %w[LICENSE README.md docs/architecture.md docs/design.md docs/optimizations.md
      docs/development.md docs/browser-check.md docs/api-reference.md
      docs/troubleshooting.md lib/paradem_pdf/browser.js lib/paradem_pdf/readiness.js
      lib/paradem_pdf/worker_context.cjs].each do |path|
      assert_includes spec.files, path
    end
    refute spec.files.any? { |path| path.match?(%r{\A(?:test/|node_modules/|\.cache/)|\.(?:pdf|ttf|otf)\z}) }
  end

  def test_gemspec_declares_ruby_3_2_minimum_without_an_upper_bound
    output, errors, status = run_ruby(<<~RUBY)
      spec = Gem::Specification.load("paradem_pdf.gemspec")
      abort "Missing package specification" unless spec
      requirement = spec.required_ruby_version
      abort "Ruby 3.1 accepted" if requirement.satisfied_by?(Gem::Version.new("3.1.9"))
      abort "Ruby 3.2 rejected" unless requirement.satisfied_by?(Gem::Version.new("3.2.0"))
      abort "Future Ruby rejected" unless requirement.satisfied_by?(Gem::Version.new("99.0.0"))
      puts "supported"
    RUBY

    assert status.success?, errors
    assert_equal "supported\n", output
  end
end
