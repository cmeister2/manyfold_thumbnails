# frozen_string_literal: true

namespace :manyfold_thumbnails do
  desc "Queue missing thumbnails for supported formats (optionally scoped to a library ID)"
  task :backfill, [:library_id] => :environment do |_task, args|
    run = ManyfoldThumbnails::Backfill.start!(library_id: args[:library_id])
    puts run.summary
  rescue ManyfoldThumbnails::Backfill::Disabled => error
    abort error.message
  end

  desc "Resume an interrupted or paused thumbnail run"
  task :resume, [:run_id] => :environment do |_task, args|
    abort "Usage: manyfold_thumbnails:resume[run_id]" unless args[:run_id]
    puts ManyfoldThumbnails::Backfill.resume!(run_id: args[:run_id]).summary
  rescue ManyfoldThumbnails::Backfill::Disabled => error
    abort error.message
  end

  desc "Show persisted counts and diagnostics (omit run ID to list all runs)"
  task :status, [:run_id] => :environment do |_task, args|
    if args[:run_id]
      run = ManyfoldThumbnails::BackfillRun.find(args[:run_id])
      puts run.summary
      puts run.message if run.message
      run.entries.where(outcome: %w[failed missing_image]).order(:model_file_id).find_each do |entry|
        puts "ModelFile #{entry.model_file_id} #{entry.filename}: #{entry.outcome}: #{entry.reason}"
      end
    else
      ManyfoldThumbnails::BackfillRun.order(:id).find_each { |run| puts run.summary }
    end
  end

  desc "Deliberately replace only the render for one supported ModelFile ID"
  task :regenerate, [:file_id] => :environment do |_task, args|
    abort "Usage: manyfold_thumbnails:regenerate[file_id]" unless args[:file_id]
    puts ManyfoldThumbnails::Backfill.regenerate!(file_id: args[:file_id]).summary
  rescue ManyfoldThumbnails::Backfill::Disabled => error
    abort error.message
  end
end
