require "test_helper"
require "paradem_pdf"
require "support/pdf_helpers"
require "support/cache_store"

class DocumentTest < Minitest::Test
  include StandaloneRuby
  include PdfHelpers

  def test_public_errors_can_be_rescued_as_library_errors
    require "paradem_pdf"

    [:Error, :InvalidPdf, :CacheWriteFailed].each do |name|
      assert ParademPdf.const_defined?(name, false), "Missing public error #{name}"
    end
    assert_operator ParademPdf::Error, :<, StandardError
    assert_operator ParademPdf::InvalidPdf, :<, ParademPdf::Error
    assert_operator ParademPdf::CacheWriteFailed, :<, ParademPdf::Error
  end

  def test_rendering_boundary_accepts_all_document_options_without_invoking_callbacks
    require "paradem_pdf"
    decoration = ->(page:, total_pages:) { flunk "Construction invoked a decoration" }
    document = ParademPdf::Document.new(
      doc_type: "invoice", body_html: "<html>Invoice</html>",
      origin: "https://documents.example.test/", locale: "en",
      header: decoration, footer: decoration, options: {format: "Letter"},
      body_margins: {bottom: "23mm"}, header_margins: {}, footer_margins: {bottom: "15mm"},
      cache: TestCacheStore.new, cache_namespace: "example", freshness: {"revision" => 1},
      assets_version: "release-1", expires_in: 60
    )

    assert_respond_to document, :to_pdf
  end

  def document(**options)
    ParademPdf::Document.new(doc_type: "invoice", body_html: "body",
      origin: "https://documents.example.test/", locale: "en", **options)
  end

  def cached_document(store, **options)
    document(cache: store, cache_namespace: "example", freshness: "snapshot-1",
      assets_version: "assets-1", expires_in: 60, **options)
  end

  def test_completed_hit_skips_all_conversion_and_callbacks
    store = TestCacheStore.new
    callbacks = []
    conversions = []
    footer = ->(page:, total_pages:) {
      callbacks << [page, total_pages]
      "footer #{page}/#{total_pages}"
    }
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      bytes = cached_document(store, footer: footer).to_pdf
      assert_equal bytes, cached_document(store, footer: footer).to_pdf(require_cache_write: true)
    end
    assert_equal ["body", "footer 1/1"], conversions
    assert_equal [[1, 1]], callbacks
    assert_equal 2, store.writes.length
  end

  def test_readiness_is_validated_before_cache_access
    store = Object.new
    [nil, 0, "true"].each do |value|
      error = assert_raises(ArgumentError) { document(cache: store, readiness: value) }
      assert_match(/readiness must be/, error.message)
    end
    [nil, 0, -1, 1.5, "20000", true, 2**31, 10**100].each do |value|
      error = assert_raises(ArgumentError) { document(cache: store, readiness_timeout: value) }
      assert_match(/readiness_timeout must be/, error.message)
    end
  end

  def test_readiness_policy_and_timeout_invalidate_completed_and_decoration_caches
    [{}, {execute_script: "custom()"}].each do |options|
      store = TestCacheStore.new
      conversions = []
      convert_using(->(_kind, html, effective, *) {
        conversions << [html, effective]
        pdf_bytes(html)
      }) do
        [{readiness: true, readiness_timeout: 20_000},
          {readiness: true, readiness_timeout: 30_000},
          {readiness: false, readiness_timeout: 30_000},
          {readiness: false, readiness_timeout: 40_000}].each do |policy|
          before = conversions.length
          doc = cached_document(store, options: options, header: ->(**) { "header" }, footer: ->(**) { "footer" }, **policy)
          doc.to_pdf
          assert_equal 3, conversions.length - before
          inputs = conversions.last(3).map(&:last)
          assert_equal 1, inputs.uniq.length, "body, header and footer must share readiness options"
          if policy[:readiness]
            assert_equal "load", inputs.first["waitUntil"]
            assert_kind_of String, inputs.first["executeScript"]
          else
            refute inputs.first.key?("waitUntil")
            if options.key?(:execute_script)
              assert_equal options[:execute_script], inputs.first["executeScript"]
            else
              refute inputs.first.key?("executeScript")
            end
          end
          doc.to_pdf
          assert_equal 3, conversions.length - before, "identical render must do zero conversions"
        end
      end
      assert_equal 12, store.writes.length
    end
  end

  def test_reuses_partial_across_documents_with_same_type_page_total_and_html
    store = TestCacheStore.new
    conversions = []
    footer = ->(page:, total_pages:) { "public #{page}/#{total_pages}" }
    convert_using(->(_kind, html, *) {
      conversions << html
      html.start_with?("body") ? pdf_bytes(html, "second") : pdf_bytes(html)
    }) do
      first = cached_document(store, body_html: "body A", footer: footer).to_pdf
      second = cached_document(store, body_html: "body B", freshness: "new snapshot", footer: footer).to_pdf
      [first, second].each do |bytes|
        ParademPdf::Document.parse_pdf(bytes).pages.each_with_index do |page, index|
          assert_includes page_text(page), "public #{index + 1}/2"
        end
      end
    end
    assert_equal ["body A", "body B"], conversions.select { |html| html.start_with?("body") }
    assert_equal ["public 1/2", "public 2/2"], conversions.select { |html| html.start_with?("public") }.sort
  end

  def test_separates_two_page_and_three_page_totals
    store = TestCacheStore.new
    conversions = []
    footer = ->(page:, total_pages:) { "footer #{page}/#{total_pages}" }
    convert_using(->(_kind, html, *) {
      conversions << html
      if html == "two"
        pdf_bytes("body", "body")
      else
        ((html == "three") ? pdf_bytes("body", "body", "body") : pdf_bytes(html))
      end
    }) do
      [2, 3].each do |total|
        bytes = cached_document(store, body_html: (total == 2) ? "two" : "three", footer: footer).to_pdf
        ParademPdf::Document.parse_pdf(bytes).pages.each_with_index do |page, index|
          assert_includes page_text(page), "footer #{index + 1}/#{total}"
        end
      end
    end
    assert_equal 7, conversions.length
  end

  def test_invalidates_page_two_decoration_without_body_changes
    store = TestCacheStore.new
    conversions = []
    second_page = "old"
    footer = ->(page:, total_pages:) { "footer #{page}/#{total_pages} #{(page == 2) ? second_page : "public"}" }
    convert_using(->(_kind, html, *) {
      conversions << html
      (html == "body") ? pdf_bytes("one", "two") : pdf_bytes(html)
    }) do
      cached_document(store, footer: footer).to_pdf
      second_page = "new"
      bytes = cached_document(store, footer: footer, freshness: {"page2" => "new"}).to_pdf
      assert_includes page_text(ParademPdf::Document.parse_pdf(bytes).pages.last), "footer 2/2 new"
    end
    assert_equal ["body", "body"], conversions.select { |html| html == "body" }
    assert_equal ["footer 1/2 public", "footer 2/2 new", "footer 2/2 old"], conversions.reject { |html| html == "body" }.sort
  end

  def test_isolates_personalized_and_translated_decorations
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      [["Alice", "en"], ["Bob", "en"], ["Bob", "ar"], ["Bob", "fa"], ["Bob", "en"]].each do |name, locale|
        footer = ->(**) { "#{name} 2026 variant A" }
        cached_document(store, locale: locale, freshness: [name, locale], footer: footer, header: ->(**) { "public" }).to_pdf
      end
    end
    assert_equal 4, conversions.count("body")
    assert_equal 3, conversions.count("public")
    assert_equal 1, conversions.count("Alice 2026 variant A")
    assert_equal 3, conversions.count("Bob 2026 variant A")
  end

  def test_completed_key_changes_for_every_declared_dimension
    changes = {doc_type: "report", body_html: "new body", origin: "https://other.example.test/", locale: "ar",
               cache_namespace: "other", freshness: {"revision" => 2}, assets_version: "assets-2",
               options: {format: "Letter"}, body_margins: {bottom: "20mm"},
               header_margins: {top: "1mm"}, footer_margins: {bottom: "1mm"},
               header: ->(**) { "header" }, footer: ->(**) { "footer" }}
    changes.each do |field, value|
      store = TestCacheStore.new
      bodies = 0
      convert_using(->(_kind, html, *) {
        bodies += 1 if html == "body" || html == "new body"
        pdf_bytes(html)
      }) do
        cached_document(store).to_pdf
        cached_document(store, **{field => value}).to_pdf
      end
      assert_equal 2, bodies, field
    end
  end

  def test_direction_date_and_variant_changes_with_declared_freshness
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      ["ltr 2026 A", "rtl 2026 A", "rtl 2027 A", "rtl 2027 B"].each do |data|
        bytes = cached_document(store, footer: ->(**) { data }, freshness: data).to_pdf
        assert_includes page_text(ParademPdf::Document.parse_pdf(bytes).pages.first), data
      end
    end
    assert_equal 8, conversions.length
  end

  def test_warm_footers_survive_completed_eviction_without_mutable_page_leaks
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      first = cached_document(store, footer: ->(**) { "footer" }).to_pdf
      completed = store.writes.last.first
      store.entries.delete(completed)
      second = cached_document(store, body_html: "another body", footer: ->(**) { "footer" }).to_pdf
      second_text = page_text(ParademPdf::Document.parse_pdf(second).pages.first)
      assert_includes second_text, "footer"
      assert_equal 1, second_text.scan("body").length
      assert_equal 1, second_text.scan("footer").length
      assert_includes page_text(ParademPdf::Document.parse_pdf(first).pages.first), "body"
      store.entries.delete(store.writes.last.first)
      third = cached_document(store, footer: ->(**) { "footer" }).to_pdf
      assert_equal 1, page_text(ParademPdf::Document.parse_pdf(third).pages.first).scan("footer").length
    end
    assert_equal ["body", "footer", "another body", "body"], conversions
  end

  def test_requires_explicit_valid_cache_dependencies_before_access
    store = TestCacheStore.new
    {cache_namespace: [nil, "", " "], freshness: [nil, Object.new, {symbol: 1}],
     assets_version: [nil, Object.new], expires_in: [nil, 0, -1, Float::INFINITY]}.each do |field, values|
      values.each { |value| assert_raises(ArgumentError) { cached_document(store, **{field => value}) } }
    end
    assert_raises(ArgumentError) { cached_document(Object.new) }
    assert_empty store.reads
    assert_empty store.writes
  end

  def test_expired_completed_and_decorations_regenerate
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
      store.now = 61
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal ["body", "footer", "body", "footer"], conversions
    assert store.writes.all? { |_, _, expiry| expiry == 60 }
  end

  def test_rejected_completed_and_overlay_writes_in_best_effort_and_strict_modes
    [false, nil].each do |rejection|
      [nil, ->(**) { "footer" }].each do |footer|
        store = TestCacheStore.new
        store.write_result = rejection
        convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
          assert_equal 1, ParademPdf::Document.parse_pdf(cached_document(store, footer: footer).to_pdf).pages.length
          assert_raises(ParademPdf::CacheWriteFailed) { cached_document(store, footer: footer).to_pdf(require_cache_write: true) }
        end
        assert_empty store.entries
      end
    end
  end

  def test_overlay_failure_never_publishes_completed_bytes_and_preserves_warm_hits
    store = TestCacheStore.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      cached_document(store, footer: ->(**) { "public" }).to_pdf
      completed = store.writes.last.first
      old_entries = store.entries.dup
      failure = RuntimeError.new("callback failed")
      assert_same failure, assert_raises(RuntimeError) {
        cached_document(store, freshness: "new", footer: ->(**) { raise failure }).to_pdf(require_cache_write: true)
      }
      assert_equal old_entries, store.entries
      assert store.entries.key?(completed)
    end
    convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("body") : pdf_bytes("one", "two") }) do
      assert_raises(ParademPdf::InvalidPdf) { cached_document(store, freshness: "invalid", footer: ->(**) { "invalid" }).to_pdf }
      assert_equal 2, store.entries.length
    end
  end

  def test_corrupt_completed_and_overlay_hits_regenerate_independently
    ["garbage", pdf_bytes("one", "two"), page_pdf(MediaBox: [0, 0, 0, 792])].each do |corruption|
      store = TestCacheStore.new
      conversions = []
      convert_using(->(_kind, html, *) {
        conversions << html
        pdf_bytes(html)
      }) do
        cached_document(store, footer: ->(**) { "footer" }).to_pdf
        overlay_key = store.writes.first.first
        completed_key = store.writes.last.first
        store.entries[completed_key] = ["garbage", 60]
        store.entries[overlay_key] = [corruption, 60]
        bytes = cached_document(store, footer: ->(**) { "footer" }).to_pdf
        assert_includes page_text(ParademPdf::Document.parse_pdf(bytes).pages.first), "footer"
      end
      assert_equal ["body", "footer", "body", "footer"], conversions
    end
  end

  def test_complete_invalidation_reuses_only_unchanged_partial_rendering_inputs
    changes = {assets_version: "new assets", options: {print_background: false},
               footer_margins: {bottom: "17mm"}, origin: "https://other.example.test/",
               locale: "ar", doc_type: "other", cache_namespace: "other"}
    changes.each do |field, value|
      store = TestCacheStore.new
      conversions = []
      convert_using(->(_kind, html, *) {
        conversions << html
        pdf_bytes(html)
      }) do
        cached_document(store, footer: ->(**) { "footer" }).to_pdf
        cached_document(store, footer: ->(**) { "footer" }, **{field => value}).to_pdf
      end
      assert_equal ["body", "footer", "body", "footer"], conversions, field
    end
  end

  def test_native_configuration_and_html_metadata_enter_completed_fingerprint
    store = TestCacheStore.new
    conversions = []
    original = Grover.configuration.options
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes("body")
    }) do
      cached_document(store, body_html: '<meta name="grover-format" content="Letter">').to_pdf
      cached_document(store, body_html: '<meta name="grover-format" content="A4">').to_pdf
      Grover.configuration.options = original.merge(timeout: 12345)
      cached_document(store, body_html: '<meta name="grover-format" content="A4">').to_pdf
    end
    assert_equal 3, conversions.length
  ensure
    Grover.configuration.options = original
  end

  def test_render_version_invalidates_completed_and_partial_keys
    store = TestCacheStore.new
    conversions = []
    original = ParademPdf::Document::RENDER_VERSION
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
      ParademPdf::Document.send(:remove_const, :RENDER_VERSION)
      ParademPdf::Document.const_set(:RENDER_VERSION, "next")
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal ["body", "footer", "body", "footer"], conversions
  ensure
    ParademPdf::Document.send(:remove_const, :RENDER_VERSION)
    ParademPdf::Document.const_set(:RENDER_VERSION, original)
  end

  def test_equivalent_native_options_and_recursive_dependencies_share_completed_hit
    store = TestCacheStore.new
    converted = false
    convert_using(->(_kind, html, *) {
      flunk "Equivalent options converted" if converted
      converted = true
      pdf_bytes(html)
    }) do
      first = cached_document(store, options: {timeout: "123", print_background: true},
        freshness: {"b" => [{"d" => 4, "c" => 3}], "a" => 1}).to_pdf
      assert_equal first, cached_document(store, options: {"print_background" => true, "timeout" => 123},
        freshness: {"a" => 1, "b" => [{"c" => 3, "d" => 4}]}).to_pdf
    end
  end

  def test_overlay_store_exceptions_propagate_without_completed_publication
    [false, true].each do |strict|
      [:read, :write].each do |operation|
        store = TestCacheStore.new
        failure = RuntimeError.new("overlay store #{operation}")
        convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
          footer = ->(**) {
            store.public_send("#{operation}_error=", failure)
            "footer"
          }
          assert_same failure, assert_raises(RuntimeError) { cached_document(store, footer: footer).to_pdf(require_cache_write: strict) }
        end
        assert_empty store.entries
      end
    end
  end

  def test_strict_completed_write_failure_keeps_successful_overlay_write
    store = TestCacheStore.new
    native_write = store.method(:write)
    store.define_singleton_method(:write) do |key, bytes, expires_in:|
      entries.empty? ? native_write.call(key, bytes, expires_in: expires_in) : false
    end
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      assert_raises(ParademPdf::CacheWriteFailed) { cached_document(store, footer: ->(**) { "footer" }).to_pdf(require_cache_write: true) }
    end
    assert_equal 1, store.entries.length
    assert_includes page_text(ParademPdf::Document.parse_pdf(store.entries.values.first.first).pages.first), "footer"
  end

  def test_invalid_overlay_geometry_and_conversion_error_never_publish_bytes
    store = TestCacheStore.new
    convert_using(->(_kind, html, *) { pdf_bytes(html, box: (html == "body") ? LETTER : A4) }) do
      assert_raises(ParademPdf::InvalidPdf) { cached_document(store, footer: ->(**) { "footer" }).to_pdf }
      assert_empty store.entries
    end
    failure = Grover::Error.new("overlay failed")
    convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes(html) : (raise failure) }) do
      assert_same failure, assert_raises(Grover::Error) { cached_document(store, footer: ->(**) { "footer" }).to_pdf }
      assert_empty store.entries
    end
  end

  def test_undeclared_hidden_callback_change_cannot_invalidate_completed_hit
    store = TestCacheStore.new
    text = "old"
    footer = ->(**) { text }
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      first = cached_document(store, footer: footer).to_pdf
      text = "new"
      assert_equal first, cached_document(store, footer: footer).to_pdf
    end
  end

  def test_identical_html_still_separates_part_kind_page_and_actual_total
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      if html.start_with?("body")
        pdf_bytes(*Array.new(html.end_with?("3") ? 3 : 2, "body"))
      else
        pdf_bytes(html)
      end
    }) do
      [2, 3].each do |total|
        cached_document(store, body_html: "body #{total}", header: ->(**) { "same" }, footer: ->(**) { "same" }).to_pdf
      end
    end
    assert_equal 10, conversions.count("same")
    assert_equal 12, store.entries.length
  end

  def test_footer_margin_change_keeps_public_header_reusable
    store = TestCacheStore.new
    conversions = []
    convert_using(->(_kind, html, *) {
      conversions << html
      pdf_bytes(html)
    }) do
      cached_document(store, header: ->(**) { "header" }, footer: ->(**) { "footer" }).to_pdf
      cached_document(store, header: ->(**) { "header" }, footer: ->(**) { "footer" }, footer_margins: {bottom: "15mm"}).to_pdf
    end
    assert_equal ["body", "body"], conversions.select { |html| html == "body" }
    assert_equal ["footer", "footer", "header"], conversions.reject { |html| html == "body" }.sort
  end

  def test_renders_each_decoration_with_actual_page_and_total
    calls = []
    header = ->(page:, total_pages:) {
      calls << [:header, page, total_pages]
      "header #{page}"
    }
    footer = ->(page:, total_pages:) {
      calls << [:footer, page, total_pages]
      "footer #{page}"
    }
    convert_using(->(_kind, html, _options, _root) {
      (html == "body") ? pdf_bytes("one", "two", "three") : pdf_bytes(html)
    }) do
      pages = CombinePDF.parse(document(header: header, footer: footer).to_pdf).pages
      assert_equal 3, pages.length
      pages.each_with_index do |page, i|
        assert_includes page_text(page), "header #{i + 1}"
        assert_includes page_text(page), "footer #{i + 1}"
      end
    end
    assert_equal [[:header, 1, 3], [:footer, 1, 3], [:header, 2, 3], [:footer, 2, 3], [:header, 3, 3], [:footer, 3, 3]], calls
  end

  def test_supports_no_header_or_footer_and_separate_margins
    calls = []
    convert_using(->(_kind, html, options, _root) {
      calls << [html, options["margin"]]
      pdf_bytes(html)
    }) do
      assert_equal 1, CombinePDF.parse(document.to_pdf).pages.length
      assert_equal [["body", {}]], calls
      calls.clear
      document(header: ->(**) { "header" }, footer: ->(**) { "footer" },
        body_margins: {top: "13mm"}, header_margins: {top: "2mm"}, footer_margins: {bottom: "15mm"}).to_pdf
      assert_equal [["body", {"top" => "13mm"}]], calls.select { |entry| entry.first == "body" }
      assert_equal [["footer", {"bottom" => "15mm"}], ["header", {"top" => "2mm"}]], calls.reject { |entry| entry.first == "body" }.sort
    end
  end

  def test_concatenates_in_input_order_and_preserves_a4
    pages = CombinePDF.parse(ParademPdf::Document.merge([pdf_bytes("one", "two", box: A4), pdf_bytes("three", box: A4)])).pages
    assert_equal 3, pages.length
    %w[one two three].each_with_index { |label, i| assert_includes page_text(pages[i]), label }
    assert_equal [A4, A4, A4], pages.map { |page| page[:MediaBox] }
  end

  def test_rejects_invalid_merge_and_generated_pdf_bytes
    [nil, [], [nil], ["garbage"], [pdf_bytes]].each do |input|
      assert_raises(ParademPdf::InvalidPdf) { ParademPdf::Document.merge(input) }
    end
    [nil, "", "garbage", pdf_bytes].each do |bytes|
      convert_using(->(*) { bytes }) { assert_raises(ParademPdf::InvalidPdf) { document.to_pdf } }
    end
  end

  def test_rejects_non_string_inputs_and_non_callable_decorations
    [:doc_type, :body_html, :origin, :locale].each do |key|
      assert_raises(ArgumentError) { document(**{key => nil}) }
    end
    [:header, :footer, :options, :body_margins, :header_margins, :footer_margins].each do |key|
      assert_raises(ArgumentError) { document(**{key => 1}) }
    end
  end

  def test_rejects_non_string_callback_output_and_multi_page_overlay
    convert_using(->(*) { pdf_bytes("body") }) do
      assert_raises(ArgumentError) { document(footer: ->(**) {}).to_pdf }
    end
    convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("body") : pdf_bytes("one", "two") }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_supports_matching_portrait_landscape_and_rotation
    [LETTER, LANDSCAPE].each do |box|
      [0, 90].each do |rotation|
        convert_using(->(_kind, html, *) { pdf_bytes(html, box: box, rotation: rotation) }) do
          page = CombinePDF.parse(document(footer: ->(**) { "footer" }).to_pdf).pages.first
          assert_equal box, page[:MediaBox]
          assert_equal rotation, page[:Rotate]
          assert_includes page_text(page), "footer"
        end
      end
    end
  end

  def test_rejects_overlay_geometry_and_rotation_mismatch
    [[LANDSCAPE, 0], [LETTER, 90], [A4, 0]].each do |box, rotation|
      convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("body") : pdf_bytes("footer", box: box, rotation: rotation) }) do
        assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
      end
    end
  end

  def test_undecorated_mixed_geometry_is_preserved
    mixed = CombinePDF.new
    mixed << CombinePDF.parse(pdf_bytes("portrait"))
    mixed << CombinePDF.parse(pdf_bytes("landscape", box: LANDSCAPE))
    convert_using(->(*) { mixed.to_pdf }) do
      pages = CombinePDF.parse(document.to_pdf).pages
      assert_equal [LETTER, LANDSCAPE], pages.map { |page| page[:MediaBox] }
    end
  end

  def test_rejects_visible_crop_box_mismatch
    overlay = CombinePDF.parse(pdf_bytes("footer"))
    overlay.pages.first[:CropBox] = [0, 0, 500, 700]
    convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("body") : overlay.to_pdf }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_conversion_and_callback_exceptions_are_not_wrapped
    failure = Grover::Error.new("native failure")
    convert_using(->(*) { raise failure }) do
      assert_same failure, assert_raises(Grover::Error) { document.to_pdf }
    end
    failure = RuntimeError.new("callback failure")
    convert_using(->(*) { pdf_bytes("body") }) do
      assert_same failure, assert_raises(RuntimeError) { document(footer: ->(**) { raise failure }).to_pdf }
    end
  end

  def test_supports_inherited_media_crop_and_rotation
    [LETTER, LANDSCAPE].each do |box|
      inherited = inherited_pdf(box: box, crop: box, rotation: 90)
      convert_using(->(_kind, html, *) { (html == "body") ? inherited : pdf_bytes("footer", box: box, rotation: 90) }) do
        page = CombinePDF.parse(document(footer: ->(**) { "footer" }).to_pdf).pages.first
        assert_equal box, page[:MediaBox]
        assert_equal box, page[:CropBox]
        assert_equal 90, page[:Rotate]
        assert_includes page_text(page), "footer"
      end
    end
    convert_using(->(_kind, html, *) { (html == "body") ? inherited_pdf(rotation: 90) : pdf_bytes("footer") }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_constructor_needs_no_application
    output, errors, status = run_ruby(<<~RUBY)
      require "paradem_pdf"
      document = ParademPdf::Document.new(
        doc_type: "invoice", body_html: "<html><body>Invoice</body></html>",
        origin: "https://documents.example.test/", locale: "en"
      )
      abort "Wrong document type" unless document.is_a?(ParademPdf::Document)
      abort "Application constant loaded" if [:Rails, :ApplicationController, :ActiveRecord].any? { |name| Object.const_defined?(name) }
      puts "document"
    RUBY

    assert status.success?, errors
    assert_equal "document\n", output
  end

  def test_opens_and_closes_one_browser_per_render
    opens = 0
    browser = FakeBrowser.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> {
      opens += 1
      browser
    }) do
      document(footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal 1, opens
    assert browser.closed?
  end

  def test_closes_browser_when_conversion_raises
    browser = FakeBrowser.new
    failure = Grover::Error.new("native failure")
    convert_using(->(*) { raise failure }, browser: -> { browser }) do
      assert_same failure, assert_raises(Grover::Error) { document.to_pdf }
    end
    assert browser.closed?
  end

  def test_batch_opens_one_browser_and_reuses_it_across_documents
    opens = 0
    browser = FakeBrowser.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> {
      opens += 1
      browser
    }) do
      ParademPdf::Document.browser do |shared|
        assert_same browser, shared
        document(footer: ->(**) { "footer" }).to_pdf(browser: shared)
        document(footer: ->(**) { "footer" }).to_pdf(browser: shared)
      end
    end
    assert_equal 1, opens
    assert browser.closed?
  end

  def test_batch_closes_browser_when_block_raises
    browser = FakeBrowser.new
    failure = RuntimeError.new("batch failed")
    convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> { browser }) do
      assert_same failure, assert_raises(RuntimeError) {
        ParademPdf::Document.browser { |_shared| raise failure }
      }
    end
    assert browser.closed?
  end

  def test_batch_requires_a_block
    assert_raises(ArgumentError) { ParademPdf::Document.browser }
  end

  def test_caller_supplied_browser_is_never_closed
    browser = FakeBrowser.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      document(footer: ->(**) { "footer" }).to_pdf(browser: browser)
    end
    refute browser.closed?
  end

  def test_explicit_endpoint_opens_nothing_and_never_enters_cache_or_fingerprints
    opens = 0
    store = TestCacheStore.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> {
      opens += 1
      FakeBrowser.new
    }) do
      cached_document(store, footer: ->(**) { "footer" }, options: {browser_ws_endpoint: "ws://explicit"}).to_pdf
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal 0, opens
    assert_equal 2, store.writes.length
    assert_equal 2, store.writes.map(&:first).uniq.length

    renderer = document(options: {browser_ws_endpoint: "ws://explicit"}).send(:renderer, "body", {})
    refute_includes renderer.fingerprint_inputs.to_s, "ws://explicit"
  end

  def test_completed_cache_hit_opens_nothing
    store = TestCacheStore.new
    opens = 0
    convert_using(->(_kind, html, *) { pdf_bytes(html) }, browser: -> {
      opens += 1
      FakeBrowser.new
    }) do
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
      opens = 0
      cached_document(store, footer: ->(**) { "footer" }).to_pdf
    end
    assert_equal 0, opens
  end

  def test_concurrency_defaults_to_processors_minus_one_with_minimum_one
    {8 => 7, 4 => 3, 2 => 1, 1 => 1, 0 => 1, nil => 1}.each do |processors, expected|
      Etc.stub(:nprocessors, processors) do
        assert_equal expected, document.instance_variable_get(:@concurrency)
      end
    end
  end

  def test_rejects_invalid_concurrency
    [0, -1, 1.5, "4"].each do |value|
      assert_raises(ArgumentError) { document(concurrency: value) }
    end
  end

  def test_browser_open_failure_raises_browser_error_and_never_converts
    converted = false
    failure = ParademPdf::BrowserError.new("launch failed")
    convert_using(->(_kind, html, *) {
      converted = true
      pdf_bytes(html)
    }, browser: -> { raise failure }) do
      assert_same failure, assert_raises(ParademPdf::BrowserError) { document.to_pdf }
    end
    refute converted
  end

  {
    missing_media: {MediaBox: nil},
    short_media: {MediaBox: [0, 0, 612]},
    long_media: {MediaBox: [0, 0, 612, 792, 1]},
    nonnumeric_media: {MediaBox: [0, 0, "wide", 792]},
    zero_media: {MediaBox: [0, 0, 0, 792]},
    reversed_media: {MediaBox: [612, 0, 0, 792]},
    zero_crop: {CropBox: [0, 0, 612, 0]},
    malformed_crop: {CropBox: "invalid"},
    disjoint_crop: {CropBox: [700, 0, 800, 792]},
    touching_crop: {CropBox: [612, 0, 800, 792]}
  }.each do |name, attributes|
    define_method("test_rejects_#{name}_through_all_pdf_boundaries") do
      assert_invalid_page_boundaries(page_pdf(**attributes))
    end
  end

  def assert_invalid_page_boundaries(bytes)
    assert_raises(ParademPdf::InvalidPdf) { ParademPdf::Document.parse_pdf(bytes) }
    assert_raises(ParademPdf::InvalidPdf) { ParademPdf::Document.merge([pdf_bytes("valid"), bytes]) }
    convert_using(->(*) { bytes }) do
      assert_raises(ParademPdf::InvalidPdf) { document.to_pdf }
    end
    convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("valid") : bytes }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_rejects_nonfinite_effective_media_and_crop_boxes
    nonfinite_box = [0, 0, "#{"9" * 400}.0", 792]
    _stdout, stderr = capture_io do
      [inherited_pdf(box: nonfinite_box), inherited_pdf(crop: nonfinite_box)].each do |bytes|
        page = CombinePDF.parse(bytes).pages.first
        assert [page[:MediaBox], page[:CropBox]].any? { |box| box.any? { |value| value.is_a?(Float) && !value.finite? } }, "Fixture must parse a nonfinite coordinate"
        assert_invalid_page_boundaries(bytes)
      end
    end
    assert_includes stderr, "out of range"
  end

  def test_rejects_user_unit_mismatch_without_scaling
    body = page_pdf(UserUnit: 2)
    overlay = page_pdf(UserUnit: 1)
    convert_using(->(_kind, html, *) { (html == "body") ? body : overlay }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_matching_nondefault_user_units_preserve_scale_and_overlay_content
    convert_using(->(_kind, html, *) {
      pdf = CombinePDF.parse(pdf_bytes(html))
      pdf.pages.first[:UserUnit] = 2
      pdf.to_pdf
    }) do
      page = ParademPdf::Document.parse_pdf(document(footer: ->(**) { "footer" }).to_pdf).pages.first
      assert_equal 2, page[:UserUnit]
      assert_equal LETTER, page[:MediaBox]
      assert_includes page_text(page), "footer"
    end
  end

  def test_rejects_different_media_clipping_despite_equal_oversized_crop_boxes
    body = page_pdf(MediaBox: [0, 0, 500, 700], CropBox: LETTER)
    overlay = page_pdf(CropBox: LETTER)
    convert_using(->(_kind, html, *) { (html == "body") ? body : overlay }) do
      assert_raises(ParademPdf::InvalidPdf) { document(footer: ->(**) { "footer" }).to_pdf }
    end
  end

  def test_matching_visible_intersections_work_without_scaling
    body = page_pdf(MediaBox: [0, 0, 500, 700], CropBox: LETTER)
    overlay = page_pdf(MediaBox: [0, 0, 500, 700], CropBox: [0, 0, 800, 900])
    convert_using(->(_kind, html, *) { (html == "body") ? body : overlay }) do
      page = ParademPdf::Document.parse_pdf(document(footer: ->(**) { "footer" }).to_pdf).pages.first
      assert_equal [0, 0, 500, 700], page[:MediaBox]
      assert_equal LETTER, page[:CropBox]
    end
  end

  def test_rejects_invalid_user_units_through_all_pdf_boundaries
    [0, -1, "invalid"].each { |unit| assert_invalid_page_boundaries(page_pdf(UserUnit: unit)) }
  end

  def test_inherited_effective_boxes_are_preserved_by_parsing_merging_and_generation
    box = [10, 20, 500, 700]
    crop = [30, 40, 450, 650]
    bytes = inherited_pdf(box: box, crop: crop)
    outputs = [bytes, ParademPdf::Document.merge([bytes])]
    convert_using(->(*) { bytes }) { outputs << document.to_pdf }
    outputs.each do |output|
      page = ParademPdf::Document.parse_pdf(output).pages.first
      assert_equal box, page[:MediaBox]
      assert_equal crop, page[:CropBox]
    end
  end

  {crop: "/CropBox null", unit: "/UserUnit null", both: "/CropBox null /UserUnit null"}.each do |name, entries|
    define_method("test_explicit_null_#{name}_uses_defaults_through_all_pdf_boundaries") do
      bytes = inherited_pdf(crop: nil, page_entries: entries)
      native_page = CombinePDF.parse(bytes).pages.first
      [:CropBox, :UserUnit].each do |key|
        next unless entries.include?("/#{key} null")
        assert native_page.key?(key), "Fixture must preserve the explicit #{key} entry"
        assert_nil native_page[key]
      end
      outputs = [bytes, ParademPdf::Document.merge([bytes])]
      convert_using(->(*) { bytes }) { outputs << document.to_pdf }
      convert_using(->(_kind, html, *) { (html == "body") ? bytes : pdf_bytes("footer") }) do
        outputs << document(footer: ->(**) { "footer" }).to_pdf
        assert_includes page_text(CombinePDF.parse(outputs.last).pages.first), "footer"
      end
      convert_using(->(_kind, html, *) { (html == "body") ? pdf_bytes("body") : bytes }) do
        outputs << document(footer: ->(**) { "footer" }).to_pdf
      end
      outputs.each do |output|
        pdf = ParademPdf::Document.parse_pdf(output)
        assert_equal 1, pdf.pages.length
        assert_equal [LETTER, 0, 1], ParademPdf::Document.page_geometry(pdf.pages.first)
      end
    rescue ParademPdf::InvalidPdf => error
      flunk "Explicit PDF null optional entries must use defaults: #{error.message}"
    end
  end
end
