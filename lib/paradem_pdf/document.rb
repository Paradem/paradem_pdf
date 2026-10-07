require "combine_pdf"

module ParademPdf
  class Document
    def initialize(doc_type:, body_html:, origin:, locale:, header: nil, footer: nil,
      options: {}, body_margins: {}, header_margins: {}, footer_margins: {},
      cache: nil, cache_namespace: nil, freshness: nil, assets_version: nil, expires_in: nil)
      @doc_type = doc_type
      @body_html = body_html
      @origin = origin
      @locale = locale
      @header = header
      @footer = footer
      @options = options
      @body_margins = body_margins
      @header_margins = header_margins
      @footer_margins = footer_margins
      @cache = cache
      @cache_namespace = cache_namespace
      @freshness = freshness
      @assets_version = assets_version
      @expires_in = expires_in
      {doc_type: doc_type, body_html: body_html, origin: origin, locale: locale}.each do |name, value|
        raise ArgumentError, "#{name} must be a String" unless value.is_a?(String)
      end
      [header, footer].each do |callback|
        raise ArgumentError, "Decorations must be callable" unless callback.nil? || callback.respond_to?(:call)
      end
      [options, body_margins, header_margins, footer_margins].each do |value|
        raise ArgumentError, "Options and margins must be Hashes" unless value.is_a?(Hash)
      end
      @origin = GroverRenderer.normalize_origin(origin)
    end

    def to_pdf(require_cache_write: false)
      body = self.class.parse_pdf(renderer(@body_html, @body_margins).to_pdf)
      total_pages = body.pages.length
      body.pages.each_with_index do |page, index|
        [[@header, @header_margins], [@footer, @footer_margins]].each do |callback, margins|
          next unless callback
          html = callback.call(page: index + 1, total_pages: total_pages)
          overlay = self.class.parse_pdf(renderer(html, margins).to_pdf)
          raise InvalidPdf, "Decorations must contain exactly one page" unless overlay.pages.length == 1
          unless geometry(page) == geometry(overlay.pages.first)
            raise InvalidPdf, "Decoration geometry and rotation must match the body page"
          end
          page << overlay.pages.first
        end
      end
      bytes = body.to_pdf
      self.class.parse_pdf(bytes)
      bytes
    end

    def self.merge(pdfs)
      raise InvalidPdf, "Provide a nonempty Array of PDFs" unless pdfs.is_a?(Array) && !pdfs.empty?
      combined = CombinePDF.new
      pdfs.each { |bytes| combined << parse_pdf(bytes) }
      bytes = combined.to_pdf
      parse_pdf(bytes)
      bytes
    end

    def self.parse_pdf(bytes)
      unless bytes.is_a?(String) && bytes.b.start_with?("%PDF-")
        raise InvalidPdf, "Expected PDF bytes"
      end
      pdf = CombinePDF.parse(bytes)
      raise InvalidPdf, "PDF must contain pages" if pdf.pages.empty?
      pdf.pages.each { |page| page_geometry(page) }
      pdf
    rescue CombinePDF::ParsingError, TypeError, ArgumentError => error
      raise InvalidPdf, "Invalid PDF: #{error.message}"
    end

    def self.page_geometry(page)
      media = validate_box(page[:MediaBox])
      crop = page[:CropBox].nil? ? media : validate_box(page[:CropBox])
      visible = validate_box([[media[0], crop[0]].max, [media[1], crop[1]].max,
        [media[2], crop[2]].min, [media[3], crop[3]].min])
      unit = page[:UserUnit]
      unit = 1 if unit.nil?
      unless unit.is_a?(Numeric) && unit.real? && unit.finite? && unit.positive?
        raise InvalidPdf, "UserUnit must be a finite positive number"
      end
      [visible, (page[:Rotate] || 0) % 360, unit]
    end

    def self.validate_box(box)
      unless box.is_a?(Array) && box.length == 4 &&
          box.all? { |value| value.is_a?(Numeric) && value.real? && value.finite? } &&
          [box[2] - box[0], box[3] - box[1]].all? { |length| length.finite? && length.positive? }
        raise InvalidPdf, "Page boxes must contain four finite coordinates with positive area"
      end
      box
    end
    private_class_method :validate_box

    private

    def renderer(html, margins)
      GroverRenderer.new(html: html, origin: @origin, options: @options, margins: margins)
    end

    def geometry(page)
      self.class.page_geometry(page)
    end
  end
end
