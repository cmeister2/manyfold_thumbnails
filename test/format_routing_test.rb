# frozen_string_literal: true

require "timeout"

class ThumbnailsPluginTest
  def test_catwalk_preserves_core_thumbnail_providers_by_default
    [:stl, :obj].each do |extension|
      assert_equal FileHandlers::F3dCli, thumbnail_handler(extension)
      refute_includes ManyfoldThumbnails::Formats.enabled_extensions, extension.to_s
      assert_nil ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("model.#{extension}"))
    end
    assert_equal FileHandlers::FreecadThumbnailExtractor, thumbnail_handler(:fcstd)
    assert_nil ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("model.fcstd"))
    [:lbrn2, :pcd].each do |extension|
      assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(extension)
      assert_includes ManyfoldThumbnails::Formats.enabled_extensions, extension.to_s
      assert_equal ManyfoldThumbnails::Catwalk,
        ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("model.#{extension}"))
    end
    refute_includes FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[:png]),
      FileHandlers::CatwalkThumbnailer
    refute_includes FileHandlers.handlers_for(environment: :browser, mime_type: Mime[:pcd]),
      FileHandlers::CatwalkThumbnailer
  end

  def test_core_reader_gaps_are_detected_from_the_current_handler_registry
    original_registry = FileHandlers::ALL_HANDLERS
    FileHandlers.send(:remove_const, :ALL_HANDLERS)
    FileHandlers.const_set(:ALL_HANDLERS, original_registry.reject { |handler| handler == FileHandlers::F3dCli }.freeze)
    Rails.cache.clear

    assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(:obj)
    assert_includes ManyfoldThumbnails::Formats.enabled_extensions, "obj"
    assert_equal ManyfoldThumbnails::Catwalk,
      ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("model.obj"))
  ensure
    if original_registry
      FileHandlers.send(:remove_const, :ALL_HANDLERS)
      FileHandlers.const_set(:ALL_HANDLERS, original_registry)
      Rails.cache.clear
    end
  end

  def test_normal_mesh_promotion_uses_the_core_renderer
    file, source = ingest(filename: "mesh.obj", source: CatwalkFixture::OBJ)
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:obj)
    assert file.has_render?
    assert_equal "image/png", file.attachment(:render).mime_type
    assert_equal source, file.attachment.read
  end

  def test_overrides_apply_to_shared_mime_extensions_and_freecad_then_can_be_removed
    assert_equal Mime[:gltf], Mime[:glb]
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:gltf)
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:glb)
    assert_equal FileHandlers::FreecadThumbnailExtractor, thumbnail_handler(:fcstd)

    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [Mime[:gltf].to_s, Mime[:fcstd].to_s])
    [:gltf, :glb, :fcstd].each do |extension|
      assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(extension)
      assert_equal ManyfoldThumbnails::Catwalk,
        ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("model.#{extension}"))
    end
    group = ManyfoldThumbnails::Formats.catwalk_groups.find { |entry| entry.fetch(:mime_type) == Mime[:gltf].to_s }
    assert_includes group.fetch(:extensions), "gltf"
    assert_includes group.fetch(:extensions), "glb"
    assert group.fetch(:overridden)

    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [])
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:gltf)
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:glb)
    assert_equal FileHandlers::FreecadThumbnailExtractor, thumbnail_handler(:fcstd)
  end

  def test_invalid_configuration_is_rejected_without_changing_persisted_overrides
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [Mime[:obj].to_s])
    ["application/x-fictional", Mime[:png].to_s, "obj"].each do |invalid|
      assert_raises(ManyfoldThumbnails::Configuration::InvalidConfiguration) do
        ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [invalid])
      end
      assert_equal [Mime[:obj].to_s], ManyfoldThumbnails::Configuration.enabled_mime_types
    end
    [nil, Mime[:obj].to_s, {Mime[:obj].to_s => "1"}, [Mime[:obj].to_s, 1]].each do |malformed|
      assert_raises(ManyfoldThumbnails::Configuration::InvalidConfiguration) do
        ManyfoldThumbnails::Configuration.update!(enabled_mime_types: malformed)
      end
      assert_equal [Mime[:obj].to_s], ManyfoldThumbnails::Configuration.enabled_mime_types
    end
  end

  def test_a_gap_format_can_be_disabled_and_reenabled
    assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(:pcd)
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types:
      ManyfoldThumbnails::Configuration.enabled_mime_types - [Mime[:pcd].to_s])
    assert_nil thumbnail_handler(:pcd)
    assert_nil ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("cloud.pcd"))
    refute_includes ManyfoldThumbnails::Formats.enabled_extensions, "pcd"
    assert ManyfoldThumbnails::Formats.supported?(filename_record("cloud.pcd"))

    ManyfoldThumbnails::Configuration.reset!
    assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(:pcd)
    assert_equal ManyfoldThumbnails::Catwalk,
      ManyfoldThumbnails::Formats.thumbnailer_for(filename_record("cloud.pcd"))
  end

  def test_persisted_overrides_refresh_a_running_worker_process
    helper = File.expand_path("support/thumbnail_handler_worker.rb", __dir__)
    output, worker_output = IO.pipe
    worker_input, input = IO.pipe
    worker_pid = fork do
      output.close
      input.close
      $stdin.reopen(worker_input)
      $stdout.reopen(worker_output)
      $stderr.reopen(worker_output)
      worker_input.close
      worker_output.close
      # A forked worker opens its own database connection and execution context.
      # Keep the shared cache intact so the test observes its warmed provider.
      ActiveRecord::Base.connection_handler.clear_all_connections!
      Rails.application.executor.perform { load helper }
      exit! 0
    rescue StandardError => error
      warn "#{error.class}: #{error.message}\n#{error.backtrace.join("\n")}"
      exit! 1
    end
    worker_input.close
    worker_output.close
    initial = routing_worker_output(output, "THUMBNAIL_ROUTING_INITIAL=")
    assert_equal "FileHandlers::F3dCli", initial
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [Mime[:obj].to_s])
    input.puts("refresh")
    input.close
    refreshed = routing_worker_output(output, "THUMBNAIL_ROUTING_REFRESHED=")
    assert_equal "FileHandlers::CatwalkThumbnailer", refreshed
    _, status = Timeout.timeout(10) { Process.wait2(worker_pid) }
    worker_pid = nil
    assert status.success?
  ensure
    [input, output, worker_input, worker_output].compact.each { |pipe| pipe.close unless pipe.closed? }
    if worker_pid
      begin
        Process.kill("TERM", worker_pid)
        Timeout.timeout(10) { Process.wait(worker_pid) }
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  def test_administrator_can_review_and_change_thumbnail_overrides
    session = browser(@users.first)
    session.get("/manyfold_thumbnails/")
    assert_equal 200, session.response.status
    document = Nokogiri::HTML(session.response.body)
    checkbox = override_checkbox(document, Mime[:obj].to_s)
    assert checkbox, "The page should show the core OBJ renderer as an available override."
    refute checkbox.key?("checked")
    assert override_checkbox(document, Mime[:pcd].to_s).key?("checked")
    assert_match(/F3[dD]/, document.text)
    assert_match(/\.lbrn2/i, document.text)
    assert_match(/not overriding/, document.at_css("#catwalk-active-overrides").text)

    session.patch("/manyfold_thumbnails/", params: {configuration: {enabled_mime_types: ["", Mime[:obj].to_s]}})
    assert_equal 302, session.response.status
    assert_equal [Mime[:obj].to_s], ManyfoldThumbnails::Configuration.enabled_mime_types
    assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(:obj)
    session.follow_redirect!
    assert_equal 200, session.response.status
    saved = Nokogiri::HTML(session.response.body)
    assert override_checkbox(saved, Mime[:obj].to_s).key?("checked")
    assert_includes saved.at_css("#catwalk-active-overrides").text, ".obj"
    refute_includes saved.at_css("#catwalk-active-overrides").text, ".pcd"

    session.patch("/manyfold_thumbnails/", params: {configuration: {enabled_mime_types: [""]}})
    assert_equal 302, session.response.status
    assert_empty ManyfoldThumbnails::Configuration.enabled_mime_types
    assert_equal FileHandlers::F3dCli, thumbnail_handler(:obj)
    assert_nil thumbnail_handler(:pcd)
  end

  def test_invalid_settings_submission_preserves_existing_overrides
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [Mime[:obj].to_s])
    session = browser(@users.first)
    session.patch("/manyfold_thumbnails/", params: {configuration: {enabled_mime_types: ["application/x-fictional"]}})
    assert_equal 422, session.response.status
    assert_equal [Mime[:obj].to_s], ManyfoldThumbnails::Configuration.enabled_mime_types
    assert_equal FileHandlers::CatwalkThumbnailer, thumbnail_handler(:obj)
  end

  def test_thumbnail_configuration_and_navigation_are_administrator_only
    previous_enabled = ManyfoldThumbnails::Configuration.enabled_mime_types
    admin = browser(@users.first)
    admin.get("/models")
    assert_equal 200, admin.response.status
    refute Nokogiri::HTML(admin.response.body).at_css("a[href^='/manyfold_thumbnails']")
    admin.get(Rails.application.routes.url_helpers.settings_plugins_path)
    assert_equal 200, admin.response.status
    document = Nokogiri::HTML(admin.response.body)
    links = document.css("a[href^='/manyfold_thumbnails']")
    assert_equal 1, links.length
    assert_equal "thumbnail-settings-link", links.first["id"]
    assert_equal "Thumbnail settings", links.first.text.strip
    assert_equal "/manyfold_thumbnails", links.first["href"].delete_suffix("/")
    assert_equal "table", links.first.parent.previous_element.name

    member = browser(@users.last)
    member.get("/models")
    assert_equal 200, member.response.status
    refute Nokogiri::HTML(member.response.body).at_css("a[href^='/manyfold_thumbnails']")
    member.get(Rails.application.routes.url_helpers.settings_plugins_path)
    assert_equal 404, member.response.status
    member.get("/manyfold_thumbnails/")
    assert_equal 404, member.response.status
    member.patch("/manyfold_thumbnails/", params: {configuration: {enabled_mime_types: [Mime[:obj].to_s]}})
    assert_equal 404, member.response.status
    assert_equal previous_enabled, ManyfoldThumbnails::Configuration.enabled_mime_types
  end

  private

  def thumbnail_handler(extension)
    FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[extension]).first
  end

  def filename_record(filename)
    Struct.new(:filename).new(filename)
  end

  def override_checkbox(document, mime_type)
    document.css("input[name='configuration[enabled_mime_types][]']").find { |input| input["value"] == mime_type }
  end

  def routing_worker_output(output, prefix)
    captured = +""
    Timeout.timeout(45) do
      output.each_line do |line|
        captured << line
        return line.split(prefix, 2).last.strip if line.include?(prefix)
      end
    end
    flunk "The routing worker exited before reporting #{prefix}:\n#{captured}"
  rescue Timeout::Error
    flunk "The routing worker timed out before reporting #{prefix}:\n#{captured}"
  end
end
