# frozen_string_literal: true

require_relative "temporary_method"

module RenderSizeSetting
  include TemporaryMethod

  def with_render_size(resolution)
    if SiteSettings.respond_to?(:model_renders_size=)
      original = SiteSettings.model_renders_size
      begin
        SiteSettings.model_renders_size = resolution
        yield
      ensure
        SiteSettings.model_renders_size = original
      end
    else
      with_temporary_method(SiteSettings, :model_renders_size, -> { resolution }) { yield }
    end
  end
end
