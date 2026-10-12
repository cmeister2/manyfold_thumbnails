# frozen_string_literal: true

module ManyfoldThumbnails
  class SettingsController < ::ApplicationController
    layout "settings"

    before_action :authorize_settings

    def show
      load_formats
    end

    def update
      Configuration.update!(enabled_mime_types: enabled_mime_types_param)
      redirect_to manyfold_thumbnails.root_path, notice: t(".success")
    rescue Configuration::InvalidConfiguration => error
      flash.now[:alert] = error.message
      load_formats
      render :show, status: :unprocessable_content
    end

    private

    def authorize_settings
      authorize :settings, (action_name == "show") ? :show? : :update?
    end

    def enabled_mime_types_param
      configuration = params.require(:configuration)
      unless configuration.is_a?(ActionController::Parameters)
        raise Configuration::InvalidConfiguration, t(".invalid_selection")
      end

      # Pass only this setting through to Configuration's validator. Strong
      # parameters would silently drop malformed array values and disable all
      # types instead of rejecting the submitted selection.
      configuration.fetch(:enabled_mime_types) do
        raise Configuration::InvalidConfiguration, t(".invalid_selection")
      end
    end

    def load_formats
      @formats = Formats.catwalk_groups
      @overridden_formats = @formats.select { |group| group[:overridden] }
    end
  end
end
