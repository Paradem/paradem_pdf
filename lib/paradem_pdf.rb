require_relative "paradem_pdf/version"
require_relative "paradem_pdf/errors"
require_relative "paradem_pdf/grover_renderer"
require_relative "paradem_pdf/cache"
require_relative "paradem_pdf/browser"
require_relative "paradem_pdf/configuration"
require_relative "paradem_pdf/document"

module ParademPdf
  def self.prune(**selectors)
    store = configuration.cache
    raise ArgumentError, "No cache is configured" unless store

    Cache.new(store: store).prune(**selectors)
  end
end
