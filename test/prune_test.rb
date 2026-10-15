require "test_helper"
require "paradem_pdf"
require "support/pdf_helpers"
require "support/cache_store"

class PruneTest < Minitest::Test
  include PdfHelpers

  class Store < TestCacheStore
    attr_reader :metadata, :selectors

    def paradem_pdf_metadata_support?
      true
    end

    def write(key, bytes, expires_in:, metadata:)
      @metadata = metadata
      super(key, bytes, expires_in: expires_in)
    end

    def paradem_pdf_prune(**selectors)
      @selectors = selectors
      {count: 2, versions: ["v1"]}
    end
  end

  def teardown
    ParademPdf.reset_configuration!
  end

  def test_metadata_capable_store_receives_document_type_and_deployment
    store = Store.new
    convert_using(->(_kind, html, *) { pdf_bytes(html) }) do
      ParademPdf::Document.new(doc_type: "invoice", locale: "en", origin: "https://example.test/",
        body_html: "body", footer: ->(**) { "footer" }, cache: store,
        cache_namespace: "app", cache_key: "body", deploy_version: "v1").to_pdf
    end
    assert_equal({"doc_type" => "invoice", "deploy_version" => "v1"}, store.metadata)
    assert_equal 2, store.writes.length
  end

  def test_prune_uses_configured_store_and_forwards_intersecting_selectors
    store = Store.new
    ParademPdf.configure { |config| config.cache = store }
    result = ParademPdf.prune(version: "v1", doc_type: "invoice", keys: %w[a b], dry_run: true)
    assert_equal({count: 2, versions: ["v1"]}, result)
    assert_equal({version: "v1", doc_type: "invoice", keys: %w[a b], dry_run: true}, store.selectors)
  end

  def test_version_only_and_single_key_are_supported
    store = Store.new
    cache = ParademPdf::Cache.new(store: store)
    cache.prune(version: "v1")
    assert_equal({version: "v1", doc_type: nil, keys: nil, dry_run: false}, store.selectors)
    cache.prune(keys: "a")
    assert_equal ["a"], store.selectors[:keys]
  end

  def test_empty_and_malformed_filters_never_broaden_deletion
    store = Store.new
    cache = ParademPdf::Cache.new(store: store)
    [{}, {keys: []}, {version: " "}, {version: "v1", doc_type: ""},
      {version: "v1", keys: [nil]}, {version: "v1", keys: false},
      {version: 1}, {keys: ["a", " "]}].each do |selectors|
      assert_raises(ArgumentError) { cache.prune(**selectors) }
    end
    assert_nil store.selectors
  end

  def test_pruning_requires_a_capable_store
    assert_raises(ArgumentError) { ParademPdf::Cache.new(store: TestCacheStore.new).prune(version: "v1") }
    assert_raises(ArgumentError) { ParademPdf.prune(version: "v1") }
  end
end
