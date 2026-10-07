module ParademPdf
  class Error < StandardError; end

  class InvalidPdf < Error; end

  class CacheWriteFailed < Error; end
end
