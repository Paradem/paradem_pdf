require "grover"
require "uri"

module ParademPdf
  # Grover 1.2.10's native normalization and private processor boundary.
  class GroverRenderer
    READINESS_SCRIPT = File.read(File.expand_path("readiness.js", __dir__)).freeze
    private_constant :READINESS_SCRIPT

    def initialize(html:, origin:, options:, margins:, readiness: true, readiness_timeout: 20_000)
      self.class.validate_readiness(readiness, readiness_timeout)
      raise ArgumentError, "HTML must be a String" unless html.is_a?(String)
      raise ArgumentError, "Options and margins must be Hashes" unless options.is_a?(Hash) && margins.is_a?(Hash)
      @origin = self.class.normalize_origin(origin)
      @html = Grover::HTMLPreprocessor.process(html, @origin, URI.parse(@origin).scheme)
      aliases = {"displayUrl" => "display_url", "raiseOnRequestFailure" => "raise_on_request_failure",
                 "waitUntil" => "wait_until", "executeScript" => "execute_script"}
      options.each do |key, value|
        control = aliases.fetch(key.to_s, key.to_s)
        next unless ["display_url", "raise_on_request_failure"].include?(control)
        effective = Grover.new("", **{control => value}).send(:normalized_options, path: nil)
        validate_controls(effective, optional: true, controls: [control])
      end
      caller_options = Grover::Utils.deep_stringify_keys(options)
      aliases.each do |native, snake|
        caller_options[snake] = caller_options.delete(native) if caller_options.key?(native)
      end
      if caller_options.key?("margin") && !caller_options["margin"].is_a?(Hash)
        raise ArgumentError, "The margin option must be a Hash"
      end
      selected_options = caller_options.merge("display_url" => @origin, "raise_on_request_failure" => true)
      selected_options["margin"] = Grover::Utils.deep_merge!(
        Grover::Utils.deep_stringify_keys(caller_options.fetch("margin", {})),
        Grover::Utils.deep_stringify_keys(margins)
      )
      baseline = Grover.new("", **selected_options).send(:normalized_options, path: nil)
      native = Grover.new(@html, **selected_options)
      @effective_options = native.send(:normalized_options, path: nil).deep_dup
      if readiness
        if [nil, false, "", 0].include?(@effective_options["waitUntil"])
          @effective_options["waitUntil"] = "load"
        end
        unless @effective_options.key?("executeScript") || @effective_options["javaScriptEnabled"] == false
          @effective_options["executeScript"] = READINESS_SCRIPT.sub("READINESS_TIMEOUT", readiness_timeout.to_s)
        end
      end
      @root_path = native.send(:root_path).deep_dup
      validate_controls(@effective_options)
      unless @effective_options["margin"] == baseline["margin"]
        raise ArgumentError, "HTML metadata conflicts with selected margins"
      end
      @browser_endpoint = @effective_options.delete("browserWsEndpoint")
      if @browser_endpoint
        parsed = Nokogiri::HTML(@html)
        endpoint_tags = parsed.xpath("//meta").select do |meta|
          meta["name"].to_s[/#{Grover.configuration.meta_tag_prefix}([a-z_-]+)/, 1] == "browser_ws_endpoint"
        end
        unless endpoint_tags.empty?
          endpoint_tags.each(&:remove)
          @html = parsed.to_html
        end
      end
      @inputs = {"html" => @html, "origin" => @origin, "options" => @effective_options,
                 "root_path" => @root_path, "readiness" => readiness, "readiness_timeout" => readiness_timeout}
    end

    def self.validate_readiness(readiness, timeout)
      unless readiness == true || readiness == false
        raise ArgumentError, "readiness must be a boolean"
      end
      unless timeout.is_a?(Integer) && timeout.positive?
        raise ArgumentError, "readiness_timeout must be a positive Integer"
      end
    end

    def self.normalize_origin(origin)
      raise ArgumentError, "Origin must be an explicit HTTP(S) URL" unless origin.is_a?(String) && !origin.strip.empty?
      uri = URI.parse(origin)
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && (1..65535).cover?(uri.port)
        raise ArgumentError, "Origin must be an HTTP(S) URL without credentials, query, or fragment"
      end
      uri.path = uri.path.sub(%r{/+\z}, "") + "/"
      uri.to_s
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid origin URL"
    end

    def fingerprint_inputs
      @inputs.deep_dup
    end

    def self.normalize_browser_options(options:)
      raise ArgumentError, "Options must be a Hash" unless options.is_a?(Hash)
      native = Grover.new("", **options)
      [native.send(:normalized_options, path: nil).deep_dup, native.send(:root_path).deep_dup]
    end

    def browser_options
      @effective_options.deep_dup
    end

    attr_reader :root_path, :browser_endpoint

    def to_pdf(browser_endpoint: nil)
      native = Grover.new("")
      native.instance_variable_set(:@root_path, @root_path)
      options = @effective_options.deep_dup
      browser_endpoint ||= @browser_endpoint
      options["browserWsEndpoint"] = browser_endpoint if browser_endpoint
      native.send(:processor).convert(:pdf, @html, options)
    end

    private

    def validate_controls(effective, optional: false, controls: [])
      if (!optional || controls.include?("display_url")) && effective["displayUrl"] != @origin
        raise ArgumentError, "display_url conflicts with origin"
      end
      if (!optional || controls.include?("raise_on_request_failure")) && effective["raiseOnRequestFailure"] != true
        raise ArgumentError, "Request failures must be rejected"
      end
    end
  end
end
