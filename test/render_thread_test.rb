require "test_helper"
require "minitest/mock"
require "paradem_pdf"
require "support/pdf_helpers"
require "support/cache_store"
require "timeout"

class RenderThreadTest < Minitest::Test
  include PdfHelpers

  def document(**options)
    ParademPdf::Document.new(doc_type: "thread-check", body_html: "body",
      origin: "https://documents.example.test/", locale: "en", concurrency: 2, **options)
  end

  def test_individual_headers_and_footers_overlap_across_pages_within_pool_limit
    bytes = {"body" => pdf_bytes("one", "two", "three", "four")}
    1.upto(4) do |page|
      ["header", "footer"].each { |kind| bytes["#{kind}#{page}"] = pdf_bytes("#{kind}#{page}") }
    end
    caller = Thread.current
    factory = Grover::Processor.method(:new)

    [1, 2, 4].each do |concurrency|
      mutex = Mutex.new
      barrier = ConditionVariable.new
      generation = 0
      arrivals = 0
      active = []
      snapshots = []
      conversions = []
      Grover::Processor.stub(:new, ->(root) {
        processor = factory.call(root)
        processor.define_singleton_method(:convert) do |_kind, html, _options|
          if html == "body"
            conversions << [html, Thread.current]
            next bytes.fetch(html)
          end
          mutex.synchronize do
            conversions << [html, Thread.current]
            active << html
            snapshots << active.dup
            current_generation = generation
            arrivals += 1
            begin
              if arrivals == concurrency
                arrivals = 0
                generation += 1
                barrier.broadcast
              else
                deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
                while generation == current_generation
                  remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                  raise Timeout::Error, "overlay conversions did not overlap" unless remaining.positive?
                  barrier.wait(mutex, remaining)
                end
              end
            ensure
              active.delete(html)
            end
          end
          bytes.fetch(html)
        end
        processor
      }) do
        ParademPdf::Browser.stub(:open, ->(**) { FakeBrowser.new }) do
          doc = document(concurrency: concurrency,
            header: ->(page:, **) { "header#{page}" }, footer: ->(page:, **) { "footer#{page}" })
          pages = CombinePDF.parse(doc.to_pdf).pages
          assert_equal 4, pages.length
          pages.each_with_index do |page, index|
            assert_includes page_text(page), "header#{index + 1}"
            assert_includes page_text(page), "footer#{index + 1}"
          end
        end
      end
      assert_equal concurrency, snapshots.map(&:length).max
      assert_equal bytes.keys.sort, conversions.map(&:first).sort
      assert_same caller, conversions.first.last
      assert conversions.drop(1).all? { |_, thread| !thread.equal?(caller) && !thread.alive? }
      assert_equal concurrency, conversions.drop(1).map(&:last).uniq.length
      if concurrency == 4
        assert snapshots.any? { |jobs| jobs.count { |html| html.start_with?("header") } > 1 }
        assert snapshots.any? { |jobs| jobs.count { |html| html.start_with?("footer") } > 1 }
        assert snapshots.any? { |jobs| jobs.any? { |html| html.start_with?("header") } && jobs.any? { |html| html.start_with?("footer") } }
      end
    end
  end

  def test_callbacks_cache_and_body_stay_on_caller_while_overlays_use_workers
    caller = Thread.current
    store = TestCacheStore.new
    cache_threads = []
    [:read, :write].each do |operation|
      original = store.method(operation)
      store.define_singleton_method(operation) do |*arguments, **keywords|
        cache_threads << Thread.current
        original.call(*arguments, **keywords)
      end
    end
    callbacks = []
    conversions = []
    browser = FakeBrowser.new
    doc = document(cache: store, cache_namespace: "threads", freshness: "v1", assets_version: "v1", expires_in: 60,
      header: ->(page:, total_pages:) {
        callbacks << [Thread.current, :header, page, total_pages]
        "header#{page}"
      },
      footer: ->(page:, total_pages:) {
        callbacks << [Thread.current, :footer, page, total_pages]
        "footer#{page}"
      })
    convert_using(->(_kind, html, *) {
      conversions << [Thread.current, html]
      (html == "body") ? pdf_bytes("one", "two") : pdf_bytes(html)
    }, browser: -> { browser }) do
      pages = CombinePDF.parse(doc.to_pdf).pages
      pages.each_with_index do |page, index|
        assert_includes page_text(page), "header#{index + 1}"
        assert_includes page_text(page), "footer#{index + 1}"
      end
    end
    assert_equal [[:header, 1, 2], [:footer, 1, 2], [:header, 2, 2], [:footer, 2, 2]], callbacks.map { |_, *input| input }
    assert callbacks.all? { |thread, *| thread.equal?(caller) }
    refute_empty cache_threads
    assert cache_threads.all? { |thread| thread.equal?(caller) }
    assert_same caller, conversions.first.first
    assert_equal 5, conversions.length
    assert conversions.drop(1).all? { |thread, _| !thread.equal?(caller) }
    assert browser.closed?
  end

  def test_job_order_error_wins_after_all_workers_finish_and_owner_closes
    body = pdf_bytes("one")
    first = RuntimeError.new("header failed")
    second = RuntimeError.new("footer failed first")
    footer_finished = Queue.new
    finished = Queue.new
    browser = FakeBrowser.new
    factory = Grover::Processor.method(:new)
    Grover::Processor.stub(:new, ->(root) {
      processor = factory.call(root)
      processor.define_singleton_method(:convert) do |_kind, html, _options|
        next body if html == "body"
        if html == "header"
          footer = footer_finished.pop
          footer.join
          finished << [:header, Thread.current, footer.alive?]
          raise first
        end
        finished << [:footer, Thread.current]
        footer_finished << Thread.current
        raise second
      end
      processor
    }) do
      ParademPdf::Browser.stub(:open, ->(**) { browser }) do
        doc = document(header: ->(**) { "header" }, footer: ->(**) { "footer" })
        error = Timeout.timeout(2) { assert_raises(RuntimeError) { doc.to_pdf } }
        assert_same first, error
      end
    end
    assert browser.closed?
    assert_equal 2, finished.size
    results = [finished.pop, finished.pop]
    assert_equal [:footer, :header], results.map(&:first)
    assert_equal false, results.last[2]
    assert results.all? { |_, thread| !thread.alive? }
  end
end
