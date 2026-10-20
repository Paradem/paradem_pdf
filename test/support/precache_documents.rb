require "support/cache_store"

class FixturePdf
  include ParademPdf::Rails::Precacheable

  class << self
    attr_accessor :entries, :calls, :document_options
  end

  def self.precache_entries
    entries
  end

  def to_pdf(label:, browser: nil, require_cache_write: false)
    self.class.calls << [label, browser, require_cache_write]
    ParademPdf::Document.new(doc_type: self.class.name, locale: "en",
      body_html: label, cache_key: label, **self.class.document_options).to_pdf(browser: browser, require_cache_write: require_cache_write)
  end
end

class FixtureGuidePdf < FixturePdf; end
class FixtureReceiptPdf < FixturePdf; end
FixtureGuideAliasPdf = FixtureGuidePdf
