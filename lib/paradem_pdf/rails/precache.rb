module ParademPdf
  module Rails
    module Precache
      Result = Data.define(:attempted, :succeeded, :failed)
      class InfrastructureError < ParademPdf::Error; end

      def self.call(documents: nil, on_warning: nil)
        configured = ParademPdf.configuration.precache_document_classes
        names = documents.nil? ? configured : documents
        [configured, names].each do |list|
          unless list.is_a?(Array) && list.all? { |name| name.is_a?(String) && name.match?(/\A[A-Z]\w*(?:::[A-Z]\w*)*\z/) }
            raise PrecacheConfigurationError, "Documents must be class-name Strings"
          end
        end
        unless (names - configured).empty?
          raise PrecacheConfigurationError, "Selection must be configured"
        end
        batches = names.dup.map do |name|
          klass = name.constantize
          unless klass.is_a?(Class) && klass.include?(Precacheable) && klass.method_defined?(:to_pdf)
            raise PrecacheConfigurationError, "Document must implement the precaching protocol"
          end
          entries = klass.precache_entries
          unless entries.is_a?(Array) && entries.all? { |entry|
            entry.is_a?(Hash) && entry.keys.all? { |key| key.is_a?(Symbol) } &&
                (entry.keys & [:browser, :require_cache_write]).empty?
          }
            raise PrecacheConfigurationError, "Entries must be document keyword Hashes"
          end
          [name, klass, entries.map(&:dup)]
        end
        return Result.new(attempted: 0, succeeded: 0, failed: 0) if batches.all? { |_, _, entries| entries.empty? }

        attempted = 0
        failed = 0
        Document.browser do |browser|
          batches.each do |name, klass, entries|
            entries.each_with_index do |entry, index|
              attempted += 1
              begin
                klass.new.to_pdf(**entry, browser: browser, require_cache_write: true)
              rescue BrowserError, PrecacheConfigurationError
                raise
              rescue => error
                failed += 1
                warning = "paradem-pdf-precache failed document=#{sanitize(name)} entry=#{index + 1} error=#{sanitize(error.class.name)}"
                ::Rails.logger.warn(warning)
                on_warning&.call(warning)
              end
            end
          end
        end
        Result.new(attempted: attempted, succeeded: attempted - failed, failed: failed)
      rescue => error
        raise InfrastructureError, "paradem-pdf-precache infrastructure error=#{sanitize(error.class.name)}", cause: nil
      end

      def self.sanitize(value)
        value.to_s.gsub(/\s+/, " ")[0, 200]
      end
    end
  end
end
