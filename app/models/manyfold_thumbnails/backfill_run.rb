# frozen_string_literal: true

module ManyfoldThumbnails
  class BackfillRun < ::ApplicationRecord
    self.table_name = "manyfold_thumbnails_backfill_runs"

    COUNTS = %w[scanned generated missing_image skipped failed].freeze
    has_many :entries, class_name: "ManyfoldThumbnails::BackfillEntry",
      foreign_key: :backfill_run_id, dependent: :delete_all

    validates :operation, inclusion: {in: %w[backfill regenerate]}
    validates :state, inclusion: {in: %w[queued running paused completed]}

    def counts
      attributes.slice(*COUNTS)
    end

    def summary
      "Run #{id} (#{operation}, #{state}): " + counts.map { |name, value| "#{name}=#{value}" }.join(", ")
    end
  end
end
