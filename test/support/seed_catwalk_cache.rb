# frozen_string_literal: true

# Container integration tests run without networking. Populate the same writable
# persistent cache used in production from separately downloaded test assets.
require "fileutils"
require "json"

plugin_root = File.expand_path("../..", __dir__)
manifest = JSON.parse(File.read(File.join(plugin_root, "config/catwalk.json")))
cache_root = ENV.fetch("MANYFOLD_THUMBNAILS_CATWALK_CACHE")
fixture_root = "/test-catwalk"

manifest.fetch("targets").each do |target|
  destination = File.join(cache_root, manifest.fetch("version"), target)
  FileUtils.mkdir_p(destination)
  metadata_path = File.join(fixture_root, target, ".manifest.json")
  release = JSON.parse(File.read(metadata_path))
  release.fetch("files").each do |file|
    name = File.basename(file.fetch("path"))
    source = File.join(fixture_root, target, name)
    FileUtils.cp(source, File.join(destination, name))
    File.chmod(name == "catwalk" ? 0o755 : 0o644, File.join(destination, name))
  end
  FileUtils.cp(metadata_path, File.join(destination, ".manifest.json"))
end
