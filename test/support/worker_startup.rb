# frozen_string_literal: true

require "/usr/src/app/config/environment"

Sidekiq.configure_server do |config|
  config.on(:startup) do
    registry = FileHandlers::ALL_HANDLERS
    raise "The worker handler registry is not frozen" unless registry.frozen?
    raise "The worker did not discover Catwalk" unless registry.include?(FileHandlers::CatwalkThumbnailer)
    [:ipt, :iam].each do |extension|
      selected = FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[extension]).first
      raise "The worker selected the wrong #{extension} thumbnail provider" unless selected == FileHandlers::CatwalkThumbnailer
    end
    [:lbrn2, :pcd].each do |extension|
      type = Mime::Type.lookup_by_extension(extension.to_s)
      selected = FileHandlers.handlers_for(environment: :thumbnail, mime_type: type).first
      raise "The worker selected the wrong #{extension} thumbnail provider" unless selected == FileHandlers::CatwalkThumbnailer
    end
    [:obj, :stl].each do |extension|
      selected = FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[extension]).first
      raise "The worker replaced core #{extension} thumbnails" unless selected == FileHandlers::F3dCli
    end
    $stdout.sync = true
    puts "THUMBNAIL_WORKER_READY"
  end
end
