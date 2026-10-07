require "combine_pdf"
require "grover"

module PdfHelpers
  LETTER = [0, 0, 612, 792].freeze
  A4 = [0, 0, 595.28, 841.89].freeze
  LANDSCAPE = [0, 0, 792, 612].freeze

  def pdf_bytes(*labels, box: LETTER, rotation: 0)
    pdf = CombinePDF.new
    labels.each do |label|
      page = CombinePDF.create_page(box)
      page[:Rotate] = rotation
      page.textbox(label, x: 30, y: 30, width: 200, height: 30)
      pdf << page
    end
    pdf.to_pdf
  end

  def convert_using(conversion)
    factory = Grover::Processor.method(:new)
    Grover::Processor.stub(:new, ->(root) {
      processor = factory.call(root)
      processor.define_singleton_method(:convert) { |kind, html, options| conversion.call(kind, html, options, root) }
      processor
    }) { yield }
  end

  def page_text(page)
    contents = [page[:Contents]].flatten
    streams = contents.map { |ref| (ref[:referenced_object] || ref)[:raw_stream_content] }.join
    streams.scan(/<([0-9a-f]+)>/i).map { |hex| [hex.first].pack("H*") }.join(" ")
  end

  def page_pdf(**attributes)
    pdf = CombinePDF.parse(pdf_bytes("fixture"))
    attributes.each do |key, value|
      if value.nil?
        pdf.pages.first.delete(key)
      else
        pdf.pages.first[key] = value
      end
    end
    pdf.to_pdf
  end

  def inherited_pdf(box: LETTER, crop: LETTER, rotation: 0, page_entries: "")
    stream = "q Q\n"
    crop_entry = crop.nil? ? "" : "/CropBox [#{crop.join(" ")}]"
    objects = ["<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Count 1 /Kids [3 0 R] /MediaBox [#{box.join(" ")}] #{crop_entry} /Rotate #{rotation} >>",
      "<< /Type /Page /Parent 2 0 R /Resources << >> /Contents 4 0 R #{page_entries} >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream"]
    bytes = +"%PDF-1.5\n"
    offsets = objects.each_with_index.map do |object, index|
      offset = bytes.bytesize
      bytes << "#{index + 1} 0 obj\n#{object}\nendobj\n"
      offset
    end
    xref = bytes.bytesize
    bytes << "xref\n0 5\n0000000000 65535 f \n"
    offsets.each { |offset| bytes << format("%010d 00000 n \n", offset) }
    bytes << "trailer\n<< /Root 1 0 R /Size 5 >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
