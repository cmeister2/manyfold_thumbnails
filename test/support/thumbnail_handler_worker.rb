# frozen_string_literal: true

# Keep this process alive while its parent changes the persisted plugin setting.
# A worker must refresh its provider without a restart or an executor reset.
$stdout.sync = true
puts "THUMBNAIL_ROUTING_INITIAL=#{FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[:obj]).first.name}"
raise "Unexpected worker command" unless $stdin.gets&.strip == "refresh"
puts "THUMBNAIL_ROUTING_REFRESHED=#{FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[:obj]).first.name}"
