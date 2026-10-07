require "json"
require "open3"
require "grover"

module ParademPdf
  # Owns one headless Chrome per render (or per batch) via a small Node launcher
  # that reuses the same puppeteer resolution Grover's worker relies on.
  class Browser
    BYPASS_FLAGS = /no-sandbox|disable-setuid-sandbox|disable-web-security|ignore-certificate-errors/
    ENDPOINT_PATTERN = /\Aws(s)?:\/\//
    CLOSE_GRACE = 5
    KILL_GRACE = 2

    def self.open(options:, root_path: nil, timeout: 30)
      reject_bypass!(options)

      normalized = Grover::Utils.normalize_object(options)
      args = Array(normalized["launchArgs"])
      headless = normalized.dig("debug", "headless")
      headless = true if headless.nil?

      payload = {
        "executablePath" => normalized["executablePath"],
        "args" => args,
        "browser" => normalized["browser"],
        "timeout" => normalized["launchTimeout"],
        "headless" => headless
      }.compact

      root_path ||= Dir.pwd
      launcher_path = File.expand_path("browser.js", __dir__)
      env = Grover.configuration.node_env_vars.merge("PARADEM_PDF_BROWSER_LAUNCHER" => "1")

      stdin, stdout, wait_thr = Open3.popen2(
        env, *Grover.configuration.js_runtime_bin, launcher_path, JSON.generate(payload),
        chdir: root_path, pgroup: true
      )

      endpoint = read_endpoint(stdout, timeout)
      return new(endpoint: endpoint, stdin: stdin, stdout: stdout, wait_thr: wait_thr) if endpoint

      kill_owned(stdin, wait_thr)
      raise BrowserError, "Browser launcher failed to report a WebSocket endpoint"
    end

    def initialize(endpoint:, stdin:, stdout:, wait_thr:)
      @endpoint = endpoint
      @stdin = stdin
      @stdout = stdout
      @wait_thr = wait_thr
      @pid = wait_thr.pid
      @closed = false
    end

    attr_reader :endpoint

    def closed?
      @closed
    end

    def close
      return if @closed
      @closed = true
      @stdin.close unless @stdin.closed?
      return if @wait_thr.join(CLOSE_GRACE)
      signal("TERM", @pid)
      return if @wait_thr.join(KILL_GRACE)
      signal("KILL", -@pid)
      @wait_thr.join
    end

    private

    def signal(sig, target)
      Process.kill(sig, target)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    class << self
      private

      def reject_bypass!(options)
        raise ArgumentError, "Sandbox bypass is not allowed" if ENV["GROVER_NO_SANDBOX"] == "true"
        args = options[:launch_args] || options["launch_args"] || options["launchArgs"] || []
        if args.any? { |arg| arg.to_s.match?(BYPASS_FLAGS) }
          raise ArgumentError, "Unsafe browser security arguments"
        end
      end

      def read_endpoint(stdout, timeout)
        endpoint = nil
        reader = Thread.new do
          while (line = stdout.gets)
            if line.match?(ENDPOINT_PATTERN)
              endpoint = line.strip
              break
            end
          end
        end
        reader.join(timeout)
        endpoint
      end

      def kill_owned(stdin, wait_thr)
        stdin.close unless stdin.closed?
        signal("TERM", wait_thr.pid)
        wait_thr.join(CLOSE_GRACE)
        signal("KILL", wait_thr.pid)
        wait_thr.join
      end

      def signal(sig, target)
        Process.kill(sig, target)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end
  end
end
