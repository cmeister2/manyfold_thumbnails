# frozen_string_literal: true

module ManyfoldThumbnails
  class BackfillJob < ::ApplicationJob
    queue_as :performance

    def perform(run_id)
      continue = false
      ProcessingLock.synchronize do
        run = BackfillRun.find(run_id)
        run.with_lock do
          next if run.state == "completed"
          unless SiteSettings.generate_model_renders
            run.update!(state: "paused", message: "Model renders are disabled. Enable them and resume this run.")
            next
          end

          run.update!(state: "running", message: nil)
          file = next_file(run)
          unless file
            if run.operation == "regenerate" && run.cursor < run.maximum_file_id
              record_outcome(run, file_id: run.model_file_id, filename: nil,
                outcome: Render::Result.new(outcome: :skipped, reason: "The source file was deleted before processing."))
            end
            run.update!(state: "completed", finished_at: Time.current)
            next
          end

          outcome = Render.new(record: file, regenerate: run.operation == "regenerate").call
          record_outcome(run, file_id: file.id, filename: file.filename, outcome: outcome)
          continue = true
        end
      end
      self.class.set(wait: 1.second).perform_later(run_id) if continue
    rescue ActiveRecord::RecordNotFound
      # Deleting a run deliberately removes the work; deleted source files are
      # simply absent from the bounded backfill scope on the next attempt.
      nil
    end

    private

    def record_outcome(run, file_id:, filename:, outcome:)
      run.entries.create!(model_file_id: file_id, filename: filename,
        outcome: outcome.outcome.to_s, reason: outcome.reason)
      run.update!(cursor: file_id, scanned: run.scanned + 1,
        outcome.outcome => run.public_send(outcome.outcome) + 1)
    end

    def next_file(run)
      if run.operation == "regenerate"
        return nil if run.cursor >= run.maximum_file_id
        ::ModelFile.find_by(id: run.model_file_id)
      else
        scope = Backfill.supported_scope.where(id: (run.cursor + 1)..run.maximum_file_id)
        scope = scope.joins(:model).where(models: {library_id: run.library_id}) if run.library_id
        scope.order(:id).first
      end
    end
  end
end
