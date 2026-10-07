module ParademPdf
  class Error < StandardError; end

  class InvalidPdf < Error; end

  class CacheWriteFailed < Error; end

  class BrowserError < Error; end
end
