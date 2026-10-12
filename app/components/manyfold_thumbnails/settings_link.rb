# frozen_string_literal: true

module Components::ManyfoldThumbnails
  class SettingsLink < Components::Base
    include Phlex::Rails::Helpers::LinkTo

    def view_template
      return unless policy(:settings).show?

      p do
        link_to view_context.manyfold_thumbnails.root_path,
          class: "btn btn-outline-secondary", rel: "nofollow", id: "thumbnail-settings-link" do
          Icon(icon: "image")
          whitespace
          plain t("manyfold_thumbnails.settings.menu")
        end
      end
    end
  end
end
