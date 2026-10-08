require_relative "lib/paradem_pdf/version"

Gem::Specification.new do |spec|
  spec.name = "paradem_pdf"
  spec.version = ParademPdf::VERSION
  spec.authors = ["Paradem"]
  spec.summary = "Standalone HTML PDF documents with per-page decorations and byte caching"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "lib/**/*.js", "lib/**/*.cjs", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "grover", "= 1.2.10"
  spec.add_dependency "combine_pdf", "~> 1.0.31"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "standard"
end
