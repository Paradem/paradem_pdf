require "paradem_pdf"
require "paradem_pdf/rails_renderer"
require "paradem_pdf/rails/precacheable"
require "paradem_pdf/rails/precache"

module ParademPdf
  module Rails
    def self.precache(documents: nil, on_warning: nil)
      ::Rails.application.reloader.wrap do
        Precache.call(documents: documents, on_warning: on_warning)
      end
    rescue Precache::InfrastructureError
      raise
    rescue => error
      raise Precache::InfrastructureError, "paradem-pdf-precache infrastructure error=#{Precache.sanitize(error.class.name)}", cause: nil
    end

    def self.document(**options)
      Document.new(**options)
    end
  end
end
