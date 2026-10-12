# frozen_string_literal: true

module ManyfoldThumbnails
  class Backfill
    class Disabled < StandardError; end

    def self.supported_scope
      # Match actual extensions, including files indexed before this plugin
      # registered their type. Host MIME aliases may include unsupported types.
      extensions = Formats.enabled_extensions
      return ::ModelFile.unscoped.none if extensions.empty?

      names = extensions.map { "LOWER(filename) LIKE ?" }.join(" OR ")
      ::ModelFile.unscoped.where(names, *extensions.map { |extension| "%.#{extension}" })
    end

    def self.start!(library_id: nil)
      ensure_enabled!
      library_id = ::Library.find(library_id).id if library_id
      scope = supported_scope
      scope = scope.joins(:model).where(models: {library_id: library_id}) if library_id
      run = BackfillRun.create!(library_id: library_id, maximum_file_id: scope.maximum(:id) || 0)
      BackfillJob.perform_later(run.id)
      run
    end

    def self.regenerate!(file_id:)
      ensure_enabled!
      file = supported_scope.find(file_id)
      run = BackfillRun.create!(operation: "regenerate", model_file_id: file.id, maximum_file_id: file.id)
      BackfillJob.perform_later(run.id)
      run
    end

    def self.resume!(run_id:)
      ensure_enabled!
      run = BackfillRun.find(run_id)
      run.with_lock { run.update!(state: "queued", message: nil) unless run.state == "completed" }
      BackfillJob.perform_later(run.id) unless run.state == "completed"
      run
    end

    def self.ensure_enabled!
      raise Disabled, "Enable model renders in Manyfold before generating thumbnails." unless SiteSettings.generate_model_renders
    end
  end
end
