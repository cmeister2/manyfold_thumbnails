# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "manyfold_thumbnails"
  spec.version = "0.0.0"
  spec.authors = ["Max Dymond"]
  spec.summary = "Model thumbnails for Manyfold using Catwalk3D"
  spec.description = "Generate thumbnails with bundled Catwalk3D for enabled design file formats."
  spec.homepage = "https://github.com/cmeister2/manyfold_thumbnails"
  # Manyfold 0.151.0 provides the required thumbnail FileHandlers API.
  # The engine also checks the API because the host loader does not enforce this floor.
  spec.metadata["manyfold_version"] = ">= 0.151.0"
  spec.files = Dir["app/**/*", "config/**/*", "db/**/*", "lib/**/*", "vendor/**/*"].select { File.file?(it) }
  spec.require_paths = ["lib"]
end
