require "test_helper"
require "paradem_pdf"
require "support/pdf_helpers"

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
      cache: Object.new, cache_namespace: "example", freshness: {"revision" => 1},
      assets_version: "release-1", expires_in: 60
    )

    assert_respond_to document, :to_pdf
  end

  def document(**options)
    ParademPdf::Document.new(doc_type: "invoice", body_html: "body",
      origin: "https://documents.example.test/", locale: "en", **options)
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
      assert_equal [["body", {"top" => "13mm"}], ["header", {"top" => "2mm"}], ["footer", {"bottom" => "15mm"}]], calls
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
