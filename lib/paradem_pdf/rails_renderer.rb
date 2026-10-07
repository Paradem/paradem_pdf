module ParademPdf
  class RailsRenderer
    def initialize(renderer:, layout:)
      @renderer = renderer
      @layout = layout
    end

    def render(template:, locals: {}, assigns: {})
      @renderer.render(template: template, layout: @layout, locals: locals, assigns: assigns)
    end
  end
end
