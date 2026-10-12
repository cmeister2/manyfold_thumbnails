# frozen_string_literal: true

module ManyfoldThumbnails
  class BackfillEntry < ::ApplicationRecord
    self.table_name = "manyfold_thumbnails_backfill_entries"

    belongs_to :backfill_run, class_name: "ManyfoldThumbnails::BackfillRun"
    validates :outcome, inclusion: {in: %w[generated missing_image skipped failed]}
  end
end
