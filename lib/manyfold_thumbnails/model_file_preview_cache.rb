# frozen_string_literal: true

module ManyfoldThumbnails
  module ModelFilePreviewCache
    # Core uses the source digest for conditional GETs. Thumbnail regeneration
    # changes the stored render without changing those source bytes.
    def cache_key_with_version
      source_key = super
      return source_key unless Formats.supported?(self)

      render = attachment_derivatives[:render]
      render ? "#{source_key}/thumbnail/#{render.id}" : source_key
    end
  end
end
