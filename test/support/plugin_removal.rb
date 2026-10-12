# frozen_string_literal: true

raise "The removed plugin was still discovered" if PluginManager.all.key?("manyfold_thumbnails")
raise "The removed plugin namespace was loaded" if defined?(ManyfoldThumbnails)
raise "The removed Catwalk handler was registered" if FileHandlers.const_defined?(:CatwalkThumbnailer, false)
raise "Plugin-only formats survived removal" if Mime::Type.lookup_by_extension("lbrn2")
raise "The core registry is not frozen" unless FileHandlers::ALL_HANDLERS.frozen?
[:ipt, :iam].each do |extension|
  handlers = FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[extension])
  raise "A removed handler was returned for #{extension}" if handlers.any? { it.name == "FileHandlers::CatwalkThumbnailer" }
end
file = ModelFile.new(filename: "after-removal.ipt", digest: "removal-source-digest")
raise "Core cache behavior was not restored" unless file.cache_key_with_version == file.digest
puts "THUMBNAIL_REMOVAL_READY"
