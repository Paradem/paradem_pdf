require "support/rails_app"

if ENV["PARADEM_PDF_RAILS_SUBPROCESS"] != "1"
  class RailsPrecacheSchedulerSubprocessTest < Minitest::Test
    include RailsSubprocess

    def test_rails_precache_scheduling
      run_rails_test(__FILE__)
    end
  end
else
  require "paradem_pdf/rails"
  require "timeout"
  require "support/precache_documents"

  class RailsPrecacheSchedulerTest < Minitest::Test
    include PdfHelpers

    def setup
      ParademPdf.reset_configuration!
      @entered = Queue.new
      @release = Queue.new
      @workers = []
      Timeout.timeout(5) { nil }
    end

    def teardown
      @workers.each do |worker|
        worker.kill if worker.alive?
        worker.join(5)
      rescue
        # A RED worker failure must not prevent cleanup of other owned threads.
        nil
      end
      ParademPdf.reset_configuration!
    end

    def take(queue)
      Timeout.timeout(5) { queue.pop }
    end

    def with_workers
      caller_thread = Thread.current
      factory = Thread.method(:new)
      Thread.stub(:new, ->(*args, &block) {
        factory.call(*args, &block).tap do |worker|
          if Thread.current == caller_thread
            worker.report_on_exception = false
            @workers << worker
          end
        end
      }) { yield }
    end

    def result
      ParademPdf::Rails::Precache::Result.new(attempted: 3, succeeded: 2, failed: 1)
    end

    def blocking_pass
      -> {
        @entered << Thread.current
        take(@release)
        result
      }
    end

    def test_background_submission_returns_before_rendering
      assert_respond_to ParademPdf::Rails, :precache_later
      with_workers do
        assert_equal :skipped, ParademPdf::Rails.precache_later
        assert_empty @workers
        ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
        ParademPdf::Rails.stub(:precache, blocking_pass) do
          assert_equal :started, ParademPdf::Rails.precache_later
          worker = take(@entered)
          refute_equal Thread.current, worker
          assert_equal [worker], @workers
          @release << true
          assert_equal worker, worker.join(5)
        end
      end
    end

    def test_busy_events_coalesce_into_one_fresh_full_pass_for_all_types
      ParademPdf.configure do |config|
        config.precache_document_classes = %w[FixtureGuidePdf FixtureReceiptPdf]
        config.origin = "https://reports.example.test/"
        config.cache_namespace = "scheduler-test"
        config.cache = TestCacheStore.new
      end
      [FixtureGuidePdf, FixtureReceiptPdf].each do |klass|
        klass.entries = [{label: "old #{klass.name}"}]
        klass.calls = []
        klass.document_options = {}
      end
      conversions = Queue.new
      with_workers do
        convert_using(->(_kind, html, *) {
          conversions << html
          if html.end_with?("FixtureGuidePdf")
            @entered << Thread.current
            take(@release)
          end
          pdf_bytes(html)
        }) do
          assert_equal :started, ParademPdf::Rails.precache_later(reason: :first)
          worker = take(@entered)
          [FixtureGuidePdf, FixtureReceiptPdf].each { |klass| klass.entries = [{label: "new #{klass.name}"}] }
          10.times { assert_equal :pending, ParademPdf::Rails.precache_later(reason: :save) }
          assert_equal [worker], @workers
          @release << true
          assert_equal worker, take(@entered)
          @release << true
          assert_equal worker, worker.join(5)
          assert_equal ["old FixtureGuidePdf", "old FixtureReceiptPdf", "new FixtureGuidePdf", "new FixtureReceiptPdf"], 4.times.map { take(conversions) }
          assert_empty conversions
        end
      end
    rescue Timeout::Error
      flunk "Pending work did not run on the existing worker"
    end

    def test_thread_creation_failure_is_contained_and_releases_admission
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      output = StringIO.new
      ::Rails.stub(:logger, Logger.new(output)) do
        Thread.stub(:new, -> { raise ThreadError, "private endpoint" }) do
          assert_equal :failed, ParademPdf::Rails.precache_later(reason: "boot\nnow")
        end
      end
      assert_match(/scheduler failed reason=boot now error=ThreadError/, output.string)
      refute_match(/private/, output.string)
      with_workers do
        ParademPdf::Rails.stub(:precache, blocking_pass) do
          assert_equal :started, ParademPdf::Rails.precache_later
          worker = take(@entered)
          @release << true
          assert_equal worker, worker.join(5)
        end
      end
    rescue ThreadError
      flunk "Thread creation failure escaped background admission"
    end

    def test_an_old_worker_cannot_release_a_new_workers_admission
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      state = ParademPdf::Rails::PrecacheScheduler.instance_variable_get(:@state)
      with_workers do
        ParademPdf::Rails.stub(:precache, blocking_pass) do
          ParademPdf::Rails.precache_later
          first = take(@entered)
          released = Queue.new
          exit_first = Queue.new
          held = false
          synchronize = state[:mutex].method(:synchronize)
          state[:mutex].stub(:synchronize, ->(&block) {
            value = synchronize.call(&block)
            if Thread.current == first && !state[:running] && !held
              held = true
              released << true
              take(exit_first)
            end
            value
          }) do
            @release << true
            take(released)
            assert_equal :started, ParademPdf::Rails.precache_later
            second = take(@entered)
            exit_first << true
            assert_equal first, first.join(5)
            assert state[:running], "Old worker released the current worker's admission"
            assert_equal :pending, ParademPdf::Rails.precache_later
            assert_equal 2, @workers.length
            @release << true
            assert_equal second, take(@entered)
            @release << true
            assert_equal second, second.join(5)
          end
        end
      end
    end

    def test_a_contained_batch_failure_still_honors_pending_work
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      attempts = 0
      pass = -> {
        attempts += 1
        @entered << Thread.current
        take(@release)
        raise "private batch failure" if attempts == 1
        result
      }
      output = StringIO.new
      ::Rails.stub(:logger, Logger.new(output)) do
        with_workers do
          ParademPdf::Rails.stub(:precache, pass) do
            assert_equal :started, ParademPdf::Rails.precache_later
            first = take(@entered)
            assert_equal :pending, ParademPdf::Rails.precache_later
            @release << true
            assert_equal first, take(@entered)
            @release << true
            assert_equal first, first.join(5)
          end
        end
      end
      assert_equal 2, attempts
      assert_match(/scheduler failed reason=manual error=RuntimeError/, output.string)
      refute_match(/private/, output.string)
    rescue Timeout::Error
      flunk "Batch failure dropped the pending pass"
    end

    def test_logger_failure_never_escapes_admission
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      logger = Object.new
      logger.define_singleton_method(:warn) { |_| raise IOError, "private log path" }
      ::Rails.stub(:logger, logger) do
        Thread.stub(:new, -> { raise ThreadError, "private endpoint" }) do
          assert_equal :failed, ParademPdf::Rails.precache_later
        end
      end
    rescue IOError
      flunk "Logger failure escaped background admission"
    end

    def test_killed_worker_releases_state_for_a_subsequent_submission
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      with_workers do
        ParademPdf::Rails.stub(:precache, blocking_pass) do
          assert_equal :started, ParademPdf::Rails.precache_later
          first = take(@entered)
          assert_equal :pending, ParademPdf::Rails.precache_later
          first.kill
          assert_equal first, first.join(5)
          assert_equal :started, ParademPdf::Rails.precache_later
          second = take(@entered)
          refute_equal first, second
          @release << true
          assert_equal second, second.join(5)
        end
      end
    end

    def test_logs_bounded_reason_counts_and_monotonic_duration_without_stdout
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      output = StringIO.new
      ticks = [100.0, 100.125]
      stdout, stderr = capture_io do
        ::Rails.stub(:logger, Logger.new(output)) do
          Process.stub(:clock_gettime, ->(clock) {
            assert_equal Process::CLOCK_MONOTONIC, clock
            ticks.shift
          }) do
            with_workers do
              ParademPdf::Rails.stub(:precache, blocking_pass) do
                assert_equal :started, ParademPdf::Rails.precache_later(reason: "boot\n" + "x" * 210)
                worker = take(@entered)
                @release << true
                assert_equal worker, worker.join(5)
              end
            end
          end
        end
      end
      assert_empty stdout
      assert_empty stderr
      assert_match(/paradem-pdf-precache complete reason=boot x{195} attempted=3 succeeded=2 failed=1 duration=0\.125/, output.string)
      assert_empty ticks
    end

    def test_reason_is_materialized_on_the_submitting_thread
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      conversions = []
      reason = Object.new
      reason.define_singleton_method(:to_s) do
        conversions << Thread.current
        "event"
      end
      with_workers do
        ParademPdf::Rails.stub(:precache, blocking_pass) do
          ParademPdf::Rails.precache_later(reason: reason)
          worker = take(@entered)
          assert_equal [Thread.current], conversions
          @release << true
          assert_equal worker, worker.join(5)
          assert_equal [Thread.current], conversions
        end
      end
    end

    def test_worker_logger_failure_and_configuration_reset_do_not_replace_admission
      ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
      state = ParademPdf::Rails::PrecacheScheduler.instance_variable_get(:@state)
      logger = Object.new
      [:info, :warn].each { |level| logger.define_singleton_method(level) { |_| raise IOError, "private log path" } }
      ::Rails.stub(:logger, logger) do
        with_workers do
          ParademPdf::Rails.stub(:precache, blocking_pass) do
            assert_equal :started, ParademPdf::Rails.precache_later
            worker = take(@entered)
            owner = state[:owner]
            ParademPdf.reset_configuration!
            ParademPdf.configuration.precache_document_classes = ["FixtureGuidePdf"]
            assert_same state, ParademPdf::Rails::PrecacheScheduler.instance_variable_get(:@state)
            assert_same owner, state[:owner]
            assert_equal :pending, ParademPdf::Rails.precache_later
            @release << true
            assert_equal worker, take(@entered)
            @release << true
            assert_equal worker, worker.join(5)
            assert_equal [false, false, nil], state.values_at(:running, :pending, :owner)
          end
        end
      end
    end
  end
end
