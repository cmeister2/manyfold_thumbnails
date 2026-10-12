# frozen_string_literal: true

module Components::ManyfoldThumbnails
  class SettingsMenu < Components::Base
    include Phlex::Rails::Helpers::LinkTo

    def view_template
      return unless policy(:settings).show?

      link_to view_context.manyfold_thumbnails.root_path,
        class: "nav-link", rel: "nofollow", id: "nav-link-thumbnail-settings" do
        Icon(icon: "image")
        whitespace
        span { t("manyfold_thumbnails.settings.menu") }
      end
    end
  end
end
