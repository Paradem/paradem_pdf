require "grover"
require "uri"

module ParademPdf
  # Grover 1.2.10's native normalization and private processor boundary.
  class GroverRenderer
    def initialize(html:, origin:, options:, margins:)
      raise ArgumentError, "HTML must be a String" unless html.is_a?(String)
      raise ArgumentError, "Options and margins must be Hashes" unless options.is_a?(Hash) && margins.is_a?(Hash)
      @origin = self.class.normalize_origin(origin)
      @html = Grover::HTMLPreprocessor.process(html, @origin, URI.parse(@origin).scheme)
      aliases = {"displayUrl" => "display_url", "raiseOnRequestFailure" => "raise_on_request_failure"}
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
      @root_path = native.send(:root_path).deep_dup
      validate_controls(@effective_options)
      unless @effective_options["margin"] == baseline["margin"]
        raise ArgumentError, "HTML metadata conflicts with selected margins"
      end
      @inputs = {"html" => @html, "origin" => @origin, "options" => @effective_options,
                 "root_path" => @root_path}
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

    def to_pdf
      native = Grover.new("")
      native.instance_variable_set(:@root_path, @root_path)
      native.send(:processor).convert(:pdf, @html, @effective_options.deep_dup)
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
