module ParademPdf
  module Rails
    module PrecacheScheduler
      @state = {mutex: Mutex.new, running: false, pending: false, owner: nil}

      def self.request(reason:)
        return :skipped if ParademPdf.configuration.precache_document_classes.empty?

        reason = Precache.sanitize(reason)
        state = @state
        owner = nil
        state[:mutex].synchronize do
          if state[:running]
            state[:pending] = true
            return :pending
          end

          owner = Object.new
          state[:running] = true
          state[:owner] = owner
          Thread.new { work(state, owner, reason) }
          :started
        end
      rescue => error
        release(state, owner) if owner
        warn_failure(reason, error)
        :failed
      end

      def self.work(state, owner, reason)
        loop do
          pass(reason)
          again = state[:mutex].synchronize do
            if state[:pending]
              state[:pending] = false
              true
            else
              state[:running] = false
              state[:owner] = nil
              false
            end
          end
          break unless again
        end
      ensure
        release(state, owner)
      end

      def self.release(state, owner)
        state[:mutex].synchronize do
          if state[:owner].equal?(owner)
            state[:running] = false
            state[:pending] = false
            state[:owner] = nil
          end
        end
      end

      def self.warn_failure(reason, error)
        ::Rails.logger.warn("paradem-pdf-precache scheduler failed reason=#{Precache.sanitize(reason)} error=#{Precache.sanitize(error.class.name)}")
      rescue
        nil
      end

      def self.pass(reason)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = ParademPdf::Rails.precache
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        ::Rails.logger.info("paradem-pdf-precache complete reason=#{Precache.sanitize(reason)} attempted=#{result.attempted} succeeded=#{result.succeeded} failed=#{result.failed} duration=#{format("%.3f", duration)}")
      rescue => error
        warn_failure(reason, error)
      end
      private_class_method :work, :release, :warn_failure, :pass
    end
  end
end
