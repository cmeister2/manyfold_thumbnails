# frozen_string_literal: true

# Container integration tests run without networking. Populate the same writable
# persistent cache used in production from separately downloaded test assets.
require "fileutils"
require "json"

plugin_root = File.expand_path("../..", __dir__)
manifest = JSON.parse(File.read(File.join(plugin_root, "config/catwalk.json")))
cache_root = ENV.fetch("MANYFOLD_THUMBNAILS_CATWALK_CACHE")
fixture_root = "/test-catwalk"

manifest.fetch("targets").each do |target, release|
  destination = File.join(cache_root, manifest.fetch("version"), target)
  FileUtils.mkdir_p(destination)
  release.fetch("files").each_key do |name|
    source = File.join(fixture_root, target, name)
    FileUtils.cp(source, File.join(destination, name))
    File.chmod(name == "catwalk" ? 0o755 : 0o644, File.join(destination, name))
  end
end
