# frozen_string_literal: true

module ManyfoldThumbnails
  class Engine < ::Rails::Engine
    engine_name "manyfold_thumbnails"

    config.to_prepare do
      require "manyfold_thumbnails/model_file_preview_cache"
      ::ModelFile.prepend(ModelFilePreviewCache) unless ::ModelFile < ModelFilePreviewCache
    end

    initializer "manyfold_thumbnails.append_migrations",
      before: "active_record.initialize_database" do |app|
      next if app.root == root

      paths["db/migrate"].expanded.each do |path|
        app.config.paths["db/migrate"] << path
      end
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::Migrator.migrations_paths = app.config.paths["db/migrate"].to_a
      end
    end

    # Core MIME registrations run in load_config_initializers. Handler discovery
    # runs in after_initialize, so require the plugin's non-reloading lib classes
    # between those phases. The registry retains these class objects.
    initializer "manyfold_thumbnails.register_thumbnail_handler",
      after: :load_config_initializers, before: :finisher_hook do
      unless defined?(FileHandlers::Base) && FileHandlers.respond_to?(:handlers_for) &&
          FileHandlers::Base.respond_to?(:can_load?) &&
          Mime[:ipt] && Mime[:iam]
        raise LoadError, "manyfold_thumbnails requires Manyfold's thumbnail FileHandlers API; " \
          "use Manyfold 0.151.0 or later."
      end

      require root.join("lib/manyfold_thumbnails/formats").to_s
      Formats.register!
      require root.join("lib/file_handlers/catwalk_thumbnailer").to_s
    end
  end
end
