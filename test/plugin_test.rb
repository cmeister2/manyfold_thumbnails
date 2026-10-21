# frozen_string_literal: true

abort "Run this test with bin/test in its disposable Manyfold container." unless
  ENV["MANYFOLD_THUMBNAILS_TEST"] == "1" && defined?(Rails.application)

require "minitest/autorun"
require "action_dispatch/testing/integration"
require "active_job/queue_adapters/test_adapter"
require "warden/test/helpers"
require "nokogiri"
require "tmpdir"
require "fileutils"
require "stringio"
require "digest"
require "shrine/storage/memory"
require_relative "support/inventor_fixture"
require_relative "support/catwalk_fixture"
require_relative "support/render_size_setting"

ActiveJob::Base.queue_adapter = :test
Warden.test_mode!

# Minitest autorun runs after rails runner closes its execution context. Rails
# 8.1 requires an active context for CurrentAttributes and settings caches.
module PluginTestExecutionContext
  def run
    # Use perform so request middleware can open its own executor without
    # resetting and completing this outer test executor twice.
    Rails.application.executor.perform { super }
  end
end
Minitest::Test.prepend(PluginTestExecutionContext)

class ThumbnailsPluginTest < Minitest::Test
  include Warden::Test::Helpers
  include RenderSizeSetting

  def setup
    @render_setting = SiteSettings.find_by(var: "generate_model_renders")&.attributes
    @catwalk_setting_present = SiteSettings.exists?(var: ManyfoldThumbnails::Configuration::SETTING_KEY)
    @catwalk_enabled_types = ManyfoldThumbnails::Configuration.enabled_mime_types
    ManyfoldThumbnails::Configuration.reset!
    SiteSettings.generate_model_renders = true
    @directory = Dir.mktmpdir("thumbnails-integration-")
    @library = Library.create!(name: "Inventor preview test", path: @directory,
      storage_service: "filesystem", path_template: "{creator}/{modelName}")
    @model = Model.create!(name: "Generated Inventor fixture", path: "model", library: @library,
      permission_preset: :private)
    @users = [:administrator, :member].map do |role|
      token = SecureRandom.hex(8)
      User.create!(username: "preview-#{token}", email: "#{token}@example.invalid",
        password: "Local-test-#{SecureRandom.hex(16)}", approved: true).tap { |user| user.add_role(role) }
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def teardown
    Warden.test_reset!
    @library&.destroy!
    @object_library&.destroy!
    @users&.each(&:destroy!)
    ModelFileUploader.storages.delete(@library.storage_key) if @library
    ModelFileUploader.storages.delete(@object_library.storage_key) if @object_library
    SiteSettings.find_by(var: "generate_model_renders")&.destroy!
    SiteSettings.create!(@render_setting) if @render_setting
    if @catwalk_setting_present
      ManyfoldThumbnails::Configuration.update!(enabled_mime_types: @catwalk_enabled_types)
    else
      ManyfoldThumbnails::Configuration.reset!
    end
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def test_engine_startup_discovers_the_handler_and_scopes_dispatch
    assert_kind_of Rails::Engine, ManyfoldThumbnails::Engine.instance
    expected = ENV["MANYFOLD_THUMBNAILS_EXPECTED_VERSION"]
    assert_equal expected, PluginManager.all.fetch("manyfold_thumbnails").version.to_s if expected.present?
    assert FileHandlers::ALL_HANDLERS.frozen?
    assert_includes FileHandlers::ALL_HANDLERS, FileHandlers::CatwalkThumbnailer
    refute FileHandlers::ALL_HANDLERS.any? { |handler| handler.name == "FileHandlers::InventorThumbnailExtractor" }
    [:ipt, :iam].each do |extension|
      assert_equal FileHandlers::CatwalkThumbnailer,
        FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[extension]).first
    end
    refute_includes FileHandlers.handlers_for(environment: :thumbnail, mime_type: Mime[:png]),
      FileHandlers::CatwalkThumbnailer
    refute_includes FileHandlers.handlers_for(environment: :browser, mime_type: Mime[:ipt]),
      FileHandlers::CatwalkThumbnailer
  end

  def test_normal_background_promotion_uses_the_configured_resolution_without_changing_source
    with_render_size("1024,1024") do
      [:ipt, :iam].each do |extension|
        file, source = ingest(filename: "fixture.#{extension}")
        assert file.has_render?
        render = file.attachment_derivatives.fetch(:render)
        assert_equal @library.storage_key, render.storage_key
        assert_equal "image/png", render.mime_type
        assert_equal [1024, 1024], render.read.byteslice(16, 8).unpack("NN")
        assert_equal source, file.attachment.read
        assert_equal Digest::SHA256.hexdigest(source),
          Digest::SHA256.file(File.join(@directory, @model.path, file.filename)).hexdigest
        assert_empty file.attachment_derivatives.keys - [:render]
      end
    end
  end

  def test_catwalk_generates_drawing_and_point_cloud_renders_on_normal_promotion
    {"drawing.LBRN2" => CatwalkFixture::LIGHTBURN,
     "cloud.pcd" => CatwalkFixture::PCD}.each do |filename, source|
      file, = ingest(filename: filename, source: source)
      assert_equal FileHandlers::CatwalkThumbnailer,
        FileHandlers.handlers_for(environment: :thumbnail, mime_type: file.mime_type).first
      assert file.is_3d_model?
      assert file.has_render?, "#{filename} should have a Catwalk render."
      render = file.attachment(:render)
      assert_equal "image/png", render.mime_type
      assert_equal [512, 512], render.read.byteslice(16, 8).unpack("NN")
      assert_equal source, file.attachment.read
    end
  end

  def test_catwalk_generates_new_native_saved_previews_on_normal_promotion
    {
      "scene.MAX" => ["application/x-3dsmax", CatwalkFixture.max],
      "model.3dm" => ["model/3dm", CatwalkFixture.rhino],
      "model.skp" => ["model/x-sketchup", CatwalkFixture.sketchup],
      "part.sldprt" => ["model/x-solidworks-part", CatwalkFixture.solidworks],
      "assembly.sldasm" => ["model/x-solidworks-assembly", CatwalkFixture.solidworks]
    }.each do |filename, (mime_type, source)|
      file, = ingest(filename: filename, source: source)
      assert_equal mime_type, file.mime_type.to_s, filename
      assert file.is_3d_model?, "#{filename} should be categorized as a model."
      assert_equal FileHandlers::CatwalkThumbnailer,
        FileHandlers.handlers_for(environment: :thumbnail, mime_type: file.mime_type).first
      assert file.has_render?, "#{filename} should have a Catwalk saved-preview render."
      render = file.attachment(:render)
      assert_equal @library.storage_key, render.storage_key
      assert_equal "image/png", render.mime_type
      assert_equal [512, 512], render.read.byteslice(16, 8).unpack("NN")
      assert_equal source, file.attachment.read
      assert_equal Digest::SHA256.hexdigest(source),
        Digest::SHA256.file(File.join(@directory, @model.path, file.filename)).hexdigest
      assert_empty file.attachment_derivatives.keys - [:render]
    end
  end

  def test_solidworks_part_and_assembly_have_independent_mime_settings
    [:sldprt, :sldasm].each do |extension|
      group = ManyfoldThumbnails::Formats.catwalk_groups.find do |entry|
        entry.fetch(:mime_type) == Mime[extension].to_s
      end
      assert_equal [extension.to_s], group.fetch(:extensions)
      assert group.fetch(:enabled)
    end
    refute_equal Mime[:sldprt], Mime[:sldasm]

    ManyfoldThumbnails::Configuration.update!(enabled_mime_types:
      ManyfoldThumbnails::Configuration.enabled_mime_types - [Mime[:sldprt].to_s])
    part, source = ingest(filename: "disabled.sldprt", source: CatwalkFixture.solidworks)
    refute part.has_render?
    assert_equal source, part.attachment.read
    assembly, = ingest(filename: "enabled.sldasm", source: CatwalkFixture.solidworks)
    assert assembly.has_render?
  end

  def test_catwalk_render_appears_on_the_lightburn_file_page_and_model_card
    file, = ingest(filename: "drawing.lbrn2", source: CatwalkFixture::LIGHTBURN)
    @model.update!(preview_file: file)
    session = browser(@users.first)
    route = Rails.application.routes.url_helpers.model_model_file_path(@model, file,
      format: file.extension, derivative: "render")
    session.get(Rails.application.routes.url_helpers.model_model_file_path(@model, file))
    assert_equal 200, session.response.status
    assert Nokogiri::HTML(session.response.body).at_css("img[src='#{route}']")
    session.get("/models")
    assert_equal 200, session.response.status
    assert Nokogiri::HTML(session.response.body).at_css("img[src='#{route}']")
    session.get(route)
    assert_equal 200, session.response.status
    assert_equal "image/png", session.response.media_type
    assert_equal file.attachment(:render).read, session.response.body.b
  end

  def test_catwalk_failure_leaves_ingestion_usable_and_render_setting_controls_dispatch
    file, source = ingest(filename: "broken.pcd", source: "invalid point cloud")
    refute file.has_render?
    assert_equal source, file.attachment.read
    SiteSettings.generate_model_renders = false
    file, source = ingest(filename: "disabled.lbrn2", source: CatwalkFixture::LIGHTBURN)
    refute file.has_render?
    assert_equal source, file.attachment.read
    file.attachment.rewind
    SiteSettings.generate_model_renders = true
    file.check_derivatives!
    assert file.reload.has_render?
  end

  def test_render_setting_prevents_automatic_extraction
    SiteSettings.generate_model_renders = false
    file, source = ingest
    assert_empty file.attachment_derivatives
    refute file.has_render?
    assert_equal source, file.attachment.read
    file.attachment.rewind
    SiteSettings.generate_model_renders = true
    file.check_derivatives!
    assert file.reload.has_render?
  end

  def test_missing_thumbnail_leaves_ingestion_usable
    source = InventorFixture.compound(streams: {"UFRxDoc" => "no preview"})
    file, = ingest(source: source)
    assert_empty file.attachment_derivatives
    assert_equal source, file.attachment.read
  end

  def test_existing_views_and_derivative_route_obey_model_permissions
    file, = ingest
    @model.update!(preview_file: file)
    session = browser(@users.first)
    route = Rails.application.routes.url_helpers.model_model_file_path(@model, file,
      format: file.extension, derivative: "render")
    session.get(Rails.application.routes.url_helpers.model_model_file_path(@model, file))
    assert_equal 200, session.response.status
    assert Nokogiri::HTML(session.response.body).at_css("img[src='#{route}']"), "File page should display the render."
    session.get("/models")
    assert_equal 200, session.response.status
    assert Nokogiri::HTML(session.response.body).at_css("img[src='#{route}']"), "Model card should display the chosen preview."
    session.get(route)
    assert_equal 200, session.response.status
    assert_equal "image/png", session.response.media_type
    assert_equal file.attachment_derivatives.fetch(:render).read, session.response.body.b

    denied = browser(@users.last)
    denied.get(route)
    assert_equal 404, denied.response.status
    refute_equal file.attachment_derivatives.fetch(:render).read, denied.response.body.b
    @model.grant_permission_to("view", @users.last)
    allowed = browser(@users.last)
    allowed.get(route)
    assert_equal 200, allowed.response.status
    assert_equal "image/png", allowed.response.media_type
  end

  def test_replacing_attachment_refreshes_render_but_editing_source_in_place_does_not
    file, = ingest
    old_image = file.attachment_derivatives.fetch(:render).read
    new_image = InventorFixture.png(color: [0, 255, 0, 255])
    replacement = InventorFixture.compound(streams: {"\u0005preview" => InventorFixture.property_set(image: new_image)})
    file.attachment = cached_upload(replacement, file.filename)
    file.save!
    promote(file)
    refreshed_render = file.reload.attachment_derivatives.fetch(:render).read
    assert_equal [512, 512], refreshed_render.byteslice(16, 8).unpack("NN")
    refute_equal old_image, refreshed_render

    File.binwrite(File.join(@directory, @model.path, file.filename),
      InventorFixture.compound(streams: {"\u0005preview" => InventorFixture.property_set(image: old_image)}))
    file.check_derivatives!
    assert_equal refreshed_render, file.reload.attachment_derivatives.fetch(:render).read
  end

  def test_regeneration_changes_the_file_page_etag
    file, = ingest
    session = browser(@users.first)
    page = Rails.application.routes.url_helpers.model_model_file_path(@model, file)
    session.get(page)
    assert_equal 200, session.response.status
    etag = session.response.headers.fetch("ETag")
    session.get(page, headers: {"HTTP_IF_NONE_MATCH" => etag})
    assert_equal 304, session.response.status

    old_id = file.attachment(:render).id
    result = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
    assert_equal :generated, result.outcome
    refute_equal old_id, file.reload.attachment(:render).id
    session.get(page, headers: {"HTTP_IF_NONE_MATCH" => etag})
    assert_equal 200, session.response.status
    refute_equal etag, session.response.headers.fetch("ETag")
  end

  def test_remote_storage_streams_work_through_shrine_local_download
    @object_library = Library.create!(name: "Object storage adapter test", storage_service: "s3",
      path: "fictional-object-library",
      s3_bucket: "fictional-local-test-bucket", s3_region: "eu-west-2",
      s3_access_key_id: "fictional-key", s3_secret_access_key: "fictional-secret",
      path_template: "{creator}/{modelName}")
    memory = Shrine::Storage::Memory.new
    resolvers = ModelFileUploader.opts.fetch(:dynamic_storage).fetch(:resolvers)
    resolver_key = resolvers.keys.find { |pattern| @object_library.storage_key.to_s.match?(pattern) }
    original_resolver = resolvers.fetch(resolver_key)
    object_library_id = @object_library.id
    resolvers[resolver_key] = lambda do |match|
      (match[1].to_i == object_library_id) ? memory : original_resolver.call(match)
    end
    model = Model.create!(name: "Remote Inventor fixture", path: "remote-model", library: @object_library)
    file, source = ingest(model: model)
    render = file.attachment_derivatives.fetch(:render)
    assert_equal @object_library.storage_key, render.storage_key
    assert_equal [512, 512], render.read.byteslice(16, 8).unpack("NN")
    assert_equal source, file.attachment.read
    assert memory.exists?(render.id)
    assert memory.exists?(file.attachment.id)

    drawing, drawing_source = ingest(model: model, filename: "remote.lbrn2", source: CatwalkFixture::LIGHTBURN)
    render = drawing.attachment(:render)
    assert_equal @object_library.storage_key, render.storage_key
    assert_equal [512, 512], render.read.byteslice(16, 8).unpack("NN")
    assert_equal drawing_source, drawing.attachment.read
    assert memory.exists?(render.id)
  ensure
    resolvers[resolver_key] = original_resolver if original_resolver
  end

  private

  def ingest(filename: "fixture.ipt", source: nil, model: @model)
    image = InventorFixture.png
    source ||= InventorFixture.compound(streams: {"\u0005preview" => InventorFixture.property_set(image: image)})
    file = model.model_files.create!(filename: filename, attachment: cached_upload(source, filename))
    assert ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job] == FilePromoteJob },
      "Ingestion should schedule the normal promotion job."
    promote(file)
    [file.reload, source, image]
  end

  def cached_upload(source, filename)
    ModelFileUploader.upload(StringIO.new(source), :cache, metadata: {"filename" => filename})
  end

  def promote(file)
    FilePromoteJob.perform_now(ModelFileUploader::Attacher.name, ModelFile.name,
      file.id, "attachment", file.attachment.data)
  end

  def browser(user)
    Warden.test_reset!
    login_as(user, scope: :user)
    ActionDispatch::Integration::Session.new(Rails.application).tap do |session|
      session.host!(PublicUrl.hostname)
      session.https! if Rails.application.config.assume_ssl
    end
  end
end

Dir[File.join(__dir__, "*_test.rb")].sort.each do |path|
  require path unless path == __FILE__
end
