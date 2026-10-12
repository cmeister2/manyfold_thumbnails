# frozen_string_literal: true

require "securerandom"

module ManyfoldThumbnails
  class Render
    Result = Struct.new(:outcome, :reason, keyword_init: true)

    def initialize(record:, regenerate: false)
      @record = record
      @regenerate = regenerate
    end

    def call
      return result(:skipped, "Model renders are disabled.") unless SiteSettings.generate_model_renders

      @record.with_lock(requires_new: true) do
        thumbnailer = Formats.thumbnailer_for(@record)
        return result(:skipped, "The file type is disabled or is not supported by this plugin.") unless thumbnailer
        return result(:skipped, "The file has no source attachment.") unless @record.attachment
        previous = @record.attachment_derivatives[:render]
        return result(:skipped, "An existing render is present.") if !@regenerate && previous&.exists?
        if @record.attachment.size.to_i > thumbnailer::MAX_SOURCE_BYTES
          return result(:failed, "The source exceeds the #{thumbnailer::MAX_SOURCE_BYTES}-byte thumbnail limit.")
        end

        extractor = nil
        derivatives = @record.attachment.open do |original|
          Shrine.with_file(original) do |source|
            extractor = thumbnailer.new(file: source, record: @record)
            extractor.call
          end
        end
        unless derivatives[:render]
          return result(extractor.status == :failed ? :failed : :missing_image, extractor.reason)
        end

        persist_render(derivatives.fetch(:render), previous)
        select_preview_if_missing
        result(:generated, extractor.reason)
      end
    rescue Shrine::AttachmentChanged
      result(:skipped, "The source attachment changed during extraction; retry the file.")
    rescue StandardError => error
      Rails.logger.warn "Thumbnail failed for ModelFile #{@record.id}: #{error.class}: #{error.message}"
      result(:failed, "#{error.class}: #{error.message}".truncate(1000))
    end

    private

    def result(outcome, reason)
      Result.new(outcome: outcome, reason: reason)
    end

    def persist_render(image, previous)
      # Core ModelFileUploader uses a deterministic derivative location. A new
      # location keeps the old object intact until the database commit succeeds.
      location = File.join(@record.model.path, ".manyfold", "derivatives", @record.filename,
        "render-#{SecureRandom.uuid}.png")
      attacher = @record.attachment_attacher
      uploaded = attacher.upload_derivative(:render, image, location: location,
        metadata: {"filename" => "render.png", "mime_type" => "image/png"})
      @record.class.current_transaction.after_rollback { remove_upload(uploaded) }
      begin
        attacher.merge_derivatives(render: uploaded)
        @record.save!(validate: false)
      rescue StandardError
        remove_upload(uploaded)
        raise
      end

      if previous && previous != uploaded
        ActiveRecord.after_all_transactions_commit do
          previous.delete
        rescue StandardError => error
          Rails.logger.warn "Could not remove replaced thumbnail: #{error.class}: #{error.message}"
        end
      end
    ensure
      image.close unless image.closed?
    end

    def remove_upload(uploaded)
      uploaded.delete if uploaded.exists?
    rescue StandardError => error
      Rails.logger.warn "Could not remove uncommitted thumbnail: #{error.class}: #{error.message}"
    end

    def select_preview_if_missing
      model = @record.model
      model.with_lock do
        next if model.preview_file_id
        selected = ::Scan::Model::ParseMetadataJob.new.send(:identify_preview_file, model).fetch(:preview_file)
        model.update!(preview_file: selected) if selected
      end
    end
  end
end
