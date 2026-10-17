# frozen_string_literal: true

module SolidWorksFixture
  def self.directory
    ENV["MANYFOLD_THUMBNAILS_NATIVE_SOLIDWORKS_FIXTURES"] ||
      (File.directory?("/test-catwalk/solidworks") ? "/test-catwalk/solidworks" :
        File.expand_path("../vendor/catwalk/solidworks", __dir__))
  end
end
