# frozen_string_literal: true

module ManyfoldThumbnails
  module Configuration
    SETTING_KEY = "manyfold_thumbnails_enabled_mime_types"
    class InvalidConfiguration < StandardError; end

    def self.enabled_mime_types
      # Workers must see changes made by the web process without retaining a
      # RailsSettings or Active Record query cache from a previous extraction.
      setting = ::SiteSettings.uncached { ::SiteSettings.find_by(var: SETTING_KEY) }
      return Formats.default_enabled_mime_types unless setting

      Array(setting.value) & Formats.catwalk_mime_types.map(&:to_s)
    end

    def self.update!(enabled_mime_types:)
      unless enabled_mime_types.is_a?(Array) && enabled_mime_types.all? { |value| value.is_a?(String) }
        raise InvalidConfiguration, "Choose formats from the thumbnail settings table."
      end

      selected = enabled_mime_types.reject(&:empty?).uniq.sort
      unless (selected - Formats.catwalk_mime_types.map(&:to_s)).empty?
        raise InvalidConfiguration, "One or more selected formats are not supported by Catwalk."
      end

      setting = ::SiteSettings.find_or_initialize_by(var: SETTING_KEY)
      setting.value = selected
      # Host model validations apply to its own declared fields. The plugin's
      # private setting is fully validated above and has no host field method.
      setting.save!(validate: false)
      clear_handler_cache!
    end

    def self.reset!
      ::SiteSettings.find_by(var: SETTING_KEY)&.destroy!
      clear_handler_cache!
    end

    def self.clear_handler_cache!
      # FileHandlers stores its ordered provider lists in the shared Rails
      # cache. Clearing these entries updates dispatch in web and workers.
      Rails.cache.delete_matched("FileHandlers_handlers_for_thumbnail_*")
    end
  end
end
