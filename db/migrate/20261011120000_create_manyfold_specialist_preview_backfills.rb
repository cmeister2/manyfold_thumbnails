# frozen_string_literal: true

class CreateManyfoldSpecialistPreviewBackfills < ActiveRecord::Migration[8.0]
  def change
    create_table :manyfold_specialist_previews_backfill_runs do |table|
      table.string :operation, null: false, default: "backfill"
      table.string :state, null: false, default: "queued"
      table.bigint :library_id
      table.bigint :model_file_id
      table.bigint :maximum_file_id, null: false, default: 0
      table.bigint :cursor, null: false, default: 0
      %i[scanned generated missing_image skipped failed].each do |count|
        table.bigint count, null: false, default: 0
      end
      table.text :message
      table.datetime :finished_at
      table.timestamps
    end

    create_table :manyfold_specialist_previews_backfill_entries do |table|
      table.bigint :backfill_run_id, null: false
      table.bigint :model_file_id, null: false
      table.string :filename
      table.string :outcome, null: false
      table.text :reason
      table.timestamps
    end
    add_index :manyfold_specialist_previews_backfill_entries,
      %i[backfill_run_id model_file_id], unique: true, name: "specialist_preview_backfill_entry"
    add_foreign_key :manyfold_specialist_previews_backfill_entries,
      :manyfold_specialist_previews_backfill_runs, column: :backfill_run_id

    # A row lock serializes plugin-owned extraction across all runs and workers.
    # It is independent of host queue concurrency, Redis lock expiry, and files.
    create_table :manyfold_specialist_previews_processing_locks
    reversible do |direction|
      direction.up { execute "INSERT INTO manyfold_specialist_previews_processing_locks (id) VALUES (1)" }
    end
  end
end
