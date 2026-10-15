require "json"
require "digest"

module ParademPdf
  class Cache
    def initialize(store:)
      unless store.respond_to?(:read) && store.respond_to?(:write)
        raise ArgumentError, "Cache store must support read and write"
      end

      @store = store
    end

    def key(inputs:)
      "paradem_pdf/#{Digest::SHA256.hexdigest(JSON.generate(self.class.canonicalize(inputs)))}"
    rescue JSON::GeneratorError => error
      raise ArgumentError, "Invalid cache inputs: #{error.message}"
    end

    def self.canonicalize(value, ancestors = [])
      case value
      when Hash, Array
        raise ArgumentError, "Cache inputs cannot contain cycles" if ancestors.include?(value.object_id)

        ancestors += [value.object_id]

        if value.is_a?(Hash)
          raise ArgumentError, "Cache input hash keys must be Strings" unless value.keys.all? { |key| key.is_a?(String) }

          value.keys.sort.to_h { |key| [key.dup, canonicalize(value[key], ancestors)] }
        else
          value.map { |item| canonicalize(item, ancestors) }
        end
      when String
        value.dup
      when Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ArgumentError, "Cache inputs must contain finite numbers" unless value.finite?

        value
      else
        raise ArgumentError, "Cache inputs must be JSON-compatible"
      end
    end

    def self.validate_expiry(expires_in)
      return if expires_in.nil?

      unless expires_in.is_a?(Numeric) && expires_in.real? && expires_in.finite? && expires_in.positive?
        raise ArgumentError, "expires_in must be a finite positive number of seconds"
      end
    end

    def read(key:, expected_pages: nil)
      cached = @store.read(key)

      begin
        validate(cached, expected_pages)
        cached
      rescue InvalidPdf
        # Invalid stored bytes are a miss. Store errors still propagate.
        nil
      end
    end

    def write(key:, bytes:, expires_in:, metadata: nil, expected_pages: nil, require_cache_write: false)
      self.class.validate_expiry(expires_in)
      validate(bytes, expected_pages)

      options = {expires_in: expires_in}
      if @store.respond_to?(:paradem_pdf_metadata_support?) && @store.paradem_pdf_metadata_support?
        options[:metadata] = metadata
      end
      written = @store.write(key, bytes, **options)
      raise CacheWriteFailed, "Cache store rejected PDF write" if require_cache_write && !written

      bytes
    end

    def fetch(key:, expires_in:, expected_pages: nil, require_cache_write: false)
      self.class.validate_expiry(expires_in)

      read(key: key, expected_pages: expected_pages) ||
        write(key: key, bytes: yield, expires_in: expires_in, expected_pages: expected_pages, require_cache_write: require_cache_write)
    end

    def prune(version: nil, doc_type: nil, keys: nil, dry_run: false)
      return {count: 0, versions: []} unless @store.respond_to?(:paradem_pdf_prune)

      keys = [keys] if keys.is_a?(String)
      [version, doc_type].compact.each do |value|
        raise ArgumentError, "Prune filters must be nonblank Strings" unless value.is_a?(String) && !value.strip.empty?
      end
      if !keys.nil? && (!keys.is_a?(Array) || keys.empty? || keys.any? { |key| !key.is_a?(String) || key.strip.empty? })
        raise ArgumentError, "keys must contain nonblank Strings"
      end
      raise ArgumentError, "Provide version, doc_type, or keys" unless version || doc_type || keys
      raise ArgumentError, "dry_run must be a boolean" unless dry_run == true || dry_run == false

      @store.paradem_pdf_prune(version: version, doc_type: doc_type, keys: keys, dry_run: dry_run)
    end

    private

    def validate(bytes, expected_pages)
      pdf = Document.parse_pdf(bytes)
      if expected_pages && pdf.pages.length != expected_pages
        raise InvalidPdf, "PDF must contain #{expected_pages} pages"
      end
    end
  end
end
