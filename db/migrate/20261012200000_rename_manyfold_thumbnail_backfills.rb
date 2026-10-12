# frozen_string_literal: true

class RenameManyfoldThumbnailBackfills < ActiveRecord::Migration[8.0]
  def change
    rename_table :manyfold_specialist_previews_backfill_runs, :manyfold_thumbnails_backfill_runs
    rename_table :manyfold_specialist_previews_backfill_entries, :manyfold_thumbnails_backfill_entries
    rename_table :manyfold_specialist_previews_processing_locks, :manyfold_thumbnails_processing_locks
    rename_index :manyfold_thumbnails_backfill_entries,
      "specialist_preview_backfill_entry", "thumbnail_backfill_entry"
  end
end
