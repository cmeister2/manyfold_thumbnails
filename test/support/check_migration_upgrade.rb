# frozen_string_literal: true

# Use an independent database to exercise an installation which already ran
# the specialist-preview migration before the plugin was renamed.
require "active_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
root = File.expand_path("../..", __dir__)
require File.join(root, "db/migrate/20261011120000_create_manyfold_specialist_preview_backfills")
require File.join(root, "db/migrate/20261012200000_rename_manyfold_thumbnail_backfills")

CreateManyfoldSpecialistPreviewBackfills.new.migrate(:up)
connection = ActiveRecord::Base.connection
connection.execute <<~SQL
  INSERT INTO manyfold_specialist_previews_backfill_runs
    (id, generated, scanned, created_at, updated_at)
  VALUES (7, 1, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
SQL
connection.execute <<~SQL
  INSERT INTO manyfold_specialist_previews_backfill_entries
    (backfill_run_id, model_file_id, filename, outcome, reason, created_at, updated_at)
  VALUES (7, 42, 'part.ipt', 'generated', 'saved image', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
SQL

migration = RenameManyfoldThumbnailBackfills.new
migration.migrate(:up)
raise "Old table survived the rename" if connection.table_exists?(:manyfold_specialist_previews_backfill_runs)
raise "Backfill counts were lost" unless connection.select_value("SELECT generated FROM manyfold_thumbnails_backfill_runs WHERE id = 7") == 1
raise "Per-file outcomes were lost" unless connection.select_value("SELECT reason FROM manyfold_thumbnails_backfill_entries WHERE backfill_run_id = 7") == "saved image"
raise "Processing lock was lost" unless connection.select_value("SELECT id FROM manyfold_thumbnails_processing_locks") == 1
raise "Entry foreign key was not renamed" unless connection.foreign_keys(:manyfold_thumbnails_backfill_entries).any? { |key| key.to_table == "manyfold_thumbnails_backfill_runs" }

migration.migrate(:down)
raise "The rename cannot be rolled back" unless connection.select_value("SELECT generated FROM manyfold_specialist_previews_backfill_runs WHERE id = 7") == 1
puts "THUMBNAIL_MIGRATION_UPGRADE_READY"
