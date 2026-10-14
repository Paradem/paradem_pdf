require "paradem_pdf"
require "paradem_pdf/rails_renderer"

module ParademPdf
  module Rails
    def self.document(**options)
      Document.new(**options)
    end
  end
end
