module ParademPdf
  module Rails
    module Precacheable
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def precache_entries
          raise PrecacheConfigurationError, "Document must define precache_entries"
        end

        def precache_affected_by?(event, payload)
          false
        end
      end
    end
  end
end
