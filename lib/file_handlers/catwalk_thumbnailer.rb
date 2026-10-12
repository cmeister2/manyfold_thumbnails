# frozen_string_literal: true

require_relative "../manyfold_thumbnails/catwalk"

class FileHandlers::CatwalkThumbnailer < FileHandlers::Base
  ENVIRONMENTS = [:thumbnail].freeze
  INPUT_TYPES = ManyfoldThumbnails::Formats.catwalk_mime_types.freeze

  def self.can_load?(type)
    super && ManyfoldThumbnails::Formats.catwalk_enabled_for_type?(type)
  end

  def self.priority
    5
  end

  def self.thumbnailer
    ManyfoldThumbnails::Catwalk
  end
end
