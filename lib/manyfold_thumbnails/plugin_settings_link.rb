# frozen_string_literal: true

module ManyfoldThumbnails
  # Manyfold 0.151.0 has no plugin configuration hook in its settings sidebar.
  # Extend the installed-plugins page without replacing the host's template.
  module PluginSettingsLink
    private

    def plugin_table
      super
      return unless @plugins.any? { |plugin| plugin.name == "manyfold_thumbnails" }

      render Components::ManyfoldThumbnails::SettingsLink.new
    end
  end
end
