# frozen_string_literal: true

ManyfoldThumbnails::Engine.routes.draw do
  root to: "manyfold_thumbnails/settings#show"
  patch "/", to: "manyfold_thumbnails/settings#update"
end
