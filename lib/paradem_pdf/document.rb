require "combine_pdf"

module ParademPdf
  class Document
    RENDER_VERSION = "1".freeze

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
      @cache = cache.nil? ? nil : Cache.new(store: cache)
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
      if @cache
        unless cache_namespace.is_a?(String) && !cache_namespace.strip.empty?
          raise ArgumentError, "Caching requires a nonblank cache_namespace"
        end
        raise ArgumentError, "Caching requires explicit freshness and assets_version" if freshness.nil? || assets_version.nil?
        @freshness = Cache.canonicalize(freshness)
        @assets_version = Cache.canonicalize(assets_version)
        Cache.validate_expiry(expires_in)
      end
    end

    def to_pdf(require_cache_write: false)
      body_renderer = renderer(@body_html, @body_margins)
      return assemble(body_renderer, require_cache_write) unless @cache

      inputs = cache_inputs("completed").merge(
        "body" => body_renderer.fingerprint_inputs, "freshness" => @freshness,
        "header_present" => !@header.nil?, "footer_present" => !@footer.nil?,
        "header_config" => renderer("", @header_margins).fingerprint_inputs,
        "footer_config" => renderer("", @footer_margins).fingerprint_inputs
      )
      @cache.fetch(key: @cache.key(inputs: inputs), expires_in: @expires_in,
        require_cache_write: require_cache_write) { assemble(body_renderer, require_cache_write) }
    end

    def assemble(body_renderer, require_cache_write)
      body = self.class.parse_pdf(body_renderer.to_pdf)
      total_pages = body.pages.length
      body.pages.each_with_index do |page, index|
        [["header", @header, @header_margins], ["footer", @footer, @footer_margins]].each do |kind, callback, margins|
          next unless callback
          html = callback.call(page: index + 1, total_pages: total_pages)
          overlay_renderer = renderer(html, margins)
          generate = -> {
            bytes = overlay_renderer.to_pdf
            validate_overlay(bytes, page)
            bytes
          }
          bytes = if @cache
            inputs = cache_inputs(kind).merge("page" => index + 1, "total_pages" => total_pages,
              "rendering" => overlay_renderer.fingerprint_inputs)
            @cache.fetch(key: @cache.key(inputs: inputs), expires_in: @expires_in,
              expected_pages: 1, require_cache_write: require_cache_write, &generate)
          else
            generate.call
          end
          overlay = validate_overlay(bytes, page)
          page << overlay.pages.first
        end
      end
      bytes = body.to_pdf
      self.class.parse_pdf(bytes)
      bytes
    end
    private :assemble

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

    def cache_inputs(kind)
      {"render_version" => RENDER_VERSION, "namespace" => @cache_namespace,
       "doc_type" => @doc_type, "locale" => @locale, "kind" => kind, "assets_version" => @assets_version}
    end

    def validate_overlay(bytes, page)
      overlay = self.class.parse_pdf(bytes)
      raise InvalidPdf, "Decorations must contain exactly one page" unless overlay.pages.length == 1
      unless geometry(page) == geometry(overlay.pages.first)
        raise InvalidPdf, "Decoration geometry and rotation must match the body page"
      end
      overlay
    end

    def renderer(html, margins)
      GroverRenderer.new(html: html, origin: @origin, options: @options, margins: margins)
    end

    def geometry(page)
      self.class.page_geometry(page)
    end
  end
end
