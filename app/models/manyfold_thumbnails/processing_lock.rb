# frozen_string_literal: true

module ManyfoldThumbnails
  class ProcessingLock < ::ApplicationRecord
    self.table_name = "manyfold_thumbnails_processing_locks"

    def self.synchronize(&block)
      find(1).with_lock(&block)
    end
  end
end
