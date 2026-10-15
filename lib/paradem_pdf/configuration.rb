module ParademPdf
  class Configuration
    UNSET = Object.new.freeze
    private_constant :UNSET

    attr_accessor :options, :cache_namespace, :origin, :cache_version, :expires_in
    attr_writer :cache

    def initialize
      @options = {}
      @cache = UNSET
    end

    def cache
      return @cache unless @cache.equal?(UNSET)

      ::Rails.cache if defined?(ParademPdf::Rails)
    end
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  def self.configure
    yield configuration
  end

  def self.reset_configuration!
    @configuration = nil
  end
end
