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

    def self.open(options: {}, effective_options: nil, root_path: nil, timeout: 30)
      timeout = 30 if timeout.nil?
      unless timeout.is_a?(Numeric) && timeout.real? && timeout.finite? && timeout.positive?
        raise ArgumentError, "Browser timeout must be finite and positive"
      end

      if effective_options
        normalized = effective_options
      else
        normalized, native_root = GroverRenderer.normalize_browser_options(options: options)
        root_path ||= native_root
      end

      payload, timeout = prepare_launch(normalized, timeout)

      root_path ||= Dir.pwd
      launcher_path = File.expand_path("browser.js", __dir__)
      env = Grover.configuration.node_env_vars.merge("PARADEM_PDF_BROWSER_LAUNCHER" => "1")

      stdin, stdout, wait_thr = Open3.popen2(
        env, *Grover.configuration.js_runtime_bin, launcher_path, JSON.generate(payload),
        chdir: root_path, pgroup: true
      )

      browser = new(endpoint: nil, stdin: stdin, stdout: stdout, wait_thr: wait_thr)
      begin
        endpoint = read_endpoint(stdout, timeout)
        raise BrowserError, "Browser launcher failed to report a WebSocket endpoint" unless endpoint

        browser.instance_variable_set(:@endpoint, endpoint)
        browser
      ensure
        browser.close unless endpoint
      end
    end

    def initialize(endpoint:, stdin:, stdout:, wait_thr:)
      @endpoint = endpoint
      @stdin = stdin
      @stdout = stdout
      @wait_thr = wait_thr
      @pid = wait_thr.pid
      @closed = false
    end

    def endpoint
      raise BrowserError, "Browser is closed" if @closed

      @endpoint
    end

    def closed?
      @closed
    end

    def close
      return if @closed

      @closed = true

      begin
        @stdin.close unless @stdin.closed?

        if @wait_thr.join(CLOSE_GRACE)
          raise BrowserError, "Browser launcher close failed (exit #{@wait_thr.value.exitstatus})" unless @wait_thr.value.success?

          return
        end

        force_cleanup
      ensure
        @stdout.close unless @stdout.closed?
      end
    end

    private

    def force_cleanup
      signal("TERM")
      unless @wait_thr.join(KILL_GRACE)
        signal("KILL")
        raise BrowserError, "Browser launcher could not be reaped" unless @wait_thr.join(KILL_GRACE)
      end

      raise BrowserError, "Browser launcher required forced cleanup"
    end

    def signal(sig)
      return if @wait_thr.join(0)

      Process.kill(sig, -@pid)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM => error
      raise BrowserError, "Browser launcher cleanup failed: #{error.message}"
    end

    def self.prepare_launch(normalized, timeout)
      reject_bypass!(normalized)

      launch_timeout = normalized["launchTimeout"]
      if !launch_timeout.nil? && !(launch_timeout.is_a?(Numeric) && launch_timeout.real? && launch_timeout.finite? && launch_timeout.positive?)
        raise ArgumentError, "Browser launch_timeout must be finite and positive"
      end

      timeout = [timeout, launch_timeout / 1000.0].max if launch_timeout

      args = normalized.fetch("launchArgs", [])
      headless = normalized.dig("debug", "headless")
      headless = true if headless.nil?

      payload = {
        "executablePath" => normalized["executablePath"],
        "args" => args,
        "browser" => normalized["browser"],
        "timeout" => normalized["launchTimeout"],
        "headless" => headless,
        "devtools" => normalized.dig("debug", "devtools")
      }.compact
      [payload, timeout]
    end
    private_class_method :prepare_launch

    def self.reject_bypass!(options)
      raise ArgumentError, "Sandbox bypass is not allowed" if ENV["GROVER_NO_SANDBOX"] == "true"

      if options.key?("launchargs")
        raise ArgumentError, "Raw browser options must use launch_args, not launchArgs"
      end

      args = options.fetch("launchArgs", [])
      unless args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) }
        raise ArgumentError, "Browser launch arguments must be an Array of Strings"
      end

      if args.any? { |arg| arg.to_s.match?(BYPASS_FLAGS) }
        raise ArgumentError, "Unsafe browser security arguments"
      end
    end
    private_class_method :reject_bypass!

    def self.read_endpoint(stdout, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      buffer = +""

      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return unless remaining.positive? && IO.select([stdout], nil, nil, remaining)

        chunk = stdout.read_nonblock(4096, exception: false)
        return if chunk.nil?
        next if chunk == :wait_readable

        buffer << chunk
        while (newline = buffer.index("\n"))
          line = buffer.slice!(0, newline + 1)
          return line.strip if line.match?(ENDPOINT_PATTERN)
        end
      end
    end
    private_class_method :read_endpoint
  end
end
