require "combine_pdf"
require "etc"

module ParademPdf
  class Document
    RENDER_VERSION = "1".freeze

    def initialize(doc_type:, body_html:, origin:, locale:, header: nil, footer: nil,
      options: {}, body_margins: {}, header_margins: {}, footer_margins: {},
      cache: nil, cache_namespace: nil, freshness: nil, assets_version: nil, expires_in: nil,
      concurrency: nil)
      @doc_type = doc_type
      @body_html = body_html
      @origin = origin
      @locale = locale
      @header = header
      @footer = footer
      @body_margins = body_margins
      @header_margins = header_margins
      @footer_margins = footer_margins
      @cache = cache.nil? ? nil : Cache.new(store: cache)
      @cache_namespace = cache_namespace
      @freshness = freshness
      @assets_version = assets_version
      @expires_in = expires_in
      @concurrency = concurrency.nil? ? [(Etc.nprocessors || 1) - 1, 1].max : concurrency
      unless @concurrency.is_a?(Integer) && @concurrency.positive?
        raise ArgumentError, "concurrency must be a positive Integer"
      end
      {doc_type: doc_type, body_html: body_html, origin: origin, locale: locale}.each do |name, value|
        raise ArgumentError, "#{name} must be a String" unless value.is_a?(String)
      end
      [header, footer].each do |callback|
        raise ArgumentError, "Decorations must be callable" unless callback.nil? || callback.respond_to?(:call)
      end
      [options, body_margins, header_margins, footer_margins].each do |value|
        raise ArgumentError, "Options and margins must be Hashes" unless value.is_a?(Hash)
      end
      @options = options.dup
      @explicit_endpoint = nil
      ["browser_ws_endpoint", "browserWsEndpoint"].each do |key|
        @explicit_endpoint = @options.delete(key) if @options.key?(key)
        @explicit_endpoint = @options.delete(key.to_sym) if @options.key?(key.to_sym)
      end
      if @explicit_endpoint && !@explicit_endpoint.to_s.match?(Browser::ENDPOINT_PATTERN)
        raise ArgumentError, "browser_ws_endpoint must be a ws:// or wss:// URL"
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

    def to_pdf(browser: nil, require_cache_write: false)
      body_renderer = renderer(@body_html, @body_margins)
      owned = nil
      provider = -> {
        return browser.endpoint if browser
        return @explicit_endpoint if @explicit_endpoint
        return body_renderer.browser_endpoint if body_renderer.browser_endpoint
        owned ||= Browser.open(effective_options: body_renderer.browser_options, root_path: body_renderer.root_path)
        owned.endpoint
      }

      if @cache
        key = @cache.key(inputs: completed_inputs(body_renderer))
        if (hit = @cache.read(key: key))
          return hit
        end
        bytes = assemble(body_renderer, provider, require_cache_write)
        @cache.write(key: key, bytes: bytes, expires_in: @expires_in, require_cache_write: require_cache_write)
        return bytes
      end

      assemble(body_renderer, provider, require_cache_write)
    ensure
      owned&.close
    end

    def self.browser(options: {}, root_path: nil, timeout: nil)
      raise ArgumentError, "Document.browser requires a block" unless block_given?
      browser = Browser.open(options: options, root_path: root_path, timeout: timeout)
      yield browser
    ensure
      browser&.close
    end

    def assemble(body_renderer, provider, require_cache_write)
      endpoint = provider.call
      body = self.class.parse_pdf(body_renderer.to_pdf(browser_endpoint: endpoint))
      total_pages = body.pages.length

      jobs = []
      body.pages.each_with_index do |page, index|
        [["header", @header, @header_margins], ["footer", @footer, @footer_margins]].each do |kind, callback, margins|
          next unless callback
          html = callback.call(page: index + 1, total_pages: total_pages)
          jobs << {page: page, kind: kind, index: index, total_pages: total_pages, renderer: renderer(html, margins)}
        end
      end

      overlays = resolve_overlays(jobs, endpoint, require_cache_write)
      jobs.each_with_index { |job, position| job[:page] << overlays[position].pages.first }

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

    def completed_inputs(body_renderer)
      cache_inputs("completed").merge(
        "body" => body_renderer.fingerprint_inputs, "freshness" => @freshness,
        "header_present" => !@header.nil?, "footer_present" => !@footer.nil?,
        "header_config" => renderer("", @header_margins).fingerprint_inputs,
        "footer_config" => renderer("", @footer_margins).fingerprint_inputs
      )
    end

    def overlay_inputs(job)
      cache_inputs(job[:kind]).merge("page" => job[:index] + 1, "total_pages" => job[:total_pages],
        "rendering" => job[:renderer].fingerprint_inputs)
    end

    def resolve_overlays(jobs, endpoint, require_cache_write)
      results = Array.new(jobs.length)
      pending = []

      jobs.each_with_index do |job, position|
        if @cache
          key = @cache.key(inputs: overlay_inputs(job))
          if (hit = @cache.read(key: key, expected_pages: 1))
            results[position] = validate_overlay(hit, job[:page])
          else
            pending << {position: position, job: job, key: key}
          end
        else
          pending << {position: position, job: job, key: nil}
        end
      end

      queue = Queue.new
      pending.each { |item| queue << item }

      workers = Array.new([@concurrency, pending.length].min) do
        Thread.new do
          loop do
            item = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            begin
              item[:bytes] = item[:job][:renderer].to_pdf(browser_endpoint: endpoint)
            rescue => error
              item[:error] = error
            end
          end
        end
      end
      workers.each(&:join)

      if (failed = pending.find { |item| item[:error] })
        raise failed[:error]
      end

      pending.each do |item|
        bytes = item[:bytes]
        results[item[:position]] = validate_overlay(bytes, item[:job][:page])
        @cache&.write(key: item[:key], bytes: bytes, expires_in: @expires_in,
          expected_pages: 1, require_cache_write: require_cache_write)
      end

      results
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
