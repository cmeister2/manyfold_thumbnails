# frozen_string_literal: true

require "stringio"
require "base64"
require "shrine/storage/memory"
require_relative "support/inventor_fixture"
require_relative "support/catwalk_fixture"

class ThumbnailBackfillWorkflowTest < Minitest::Test
  PNG = Base64.strict_decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==").freeze
  SOURCE = "Fictional Inventor source for the derivative workflow tests.".freeze

  def setup
    @original_render_setting = SiteSettings.generate_model_renders
    @catwalk_setting_present = SiteSettings.exists?(var: ManyfoldThumbnails::Configuration::SETTING_KEY)
    @catwalk_enabled_types = ManyfoldThumbnails::Configuration.enabled_mime_types
    ManyfoldThumbnails::Configuration.reset!
    SiteSettings.generate_model_renders = false
    @directory = Dir.mktmpdir("thumbnail-backfill-")
    @library = Library.create!(name: "Thumbnail workflow test", path: @directory,
      storage_service: "filesystem", path_template: "{modelName}")
    @model = Model.create!(name: "Thumbnail workflow model", path: "example", library: @library)
    FileUtils.mkdir_p(File.join(@directory, @model.path))
    @runs = []
  end

  def teardown
    @runs.each { |run| run.destroy! }
    @library.destroy!
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
    SiteSettings.generate_model_renders = @original_render_setting
    if @catwalk_setting_present
      ManyfoldThumbnails::Configuration.update!(enabled_mime_types: @catwalk_enabled_types)
    else
      ManyfoldThumbnails::Configuration.reset!
    end
  end

  def test_backfill_is_scoped_persistent_and_resumes_without_reextracting_successes
    part = source("part.ipt")
    missing = source("no-preview.iam")
    malformed = source("malformed.ipt")
    rendered = source("rendered.iam")
    ignored = source("ignored.txt")
    add_derivatives(rendered, render: PNG)
    calls = []
    statuses = {part.filename => :generated, missing.filename => :missing_image, malformed.filename => :failed}
    SiteSettings.generate_model_renders = true

    with_extractor(statuses, calls) do
      run = keep(ManyfoldThumbnails::Backfill.start!(library_id: @library.id))
      ManyfoldThumbnails::BackfillJob.perform_now(run.id)
      assert_equal part.id, run.reload.cursor
      assert_equal 1, run.generated
      assert_equal part.id, @model.reload.preview_file_id

      SiteSettings.generate_model_renders = false
      ManyfoldThumbnails::BackfillJob.perform_now(run.id)
      assert_equal "paused", run.reload.state
      assert_equal 1, run.scanned
      SiteSettings.generate_model_renders = true
      ManyfoldThumbnails::Backfill.resume!(run_id: run.id)
      finish(run)

      assert_equal({"scanned" => 4, "generated" => 1, "missing_image" => 1, "skipped" => 1, "failed" => 1}, run.reload.counts)
      assert_equal [part.filename, missing.filename, malformed.filename], calls
      assert_equal %w[generated missing_image failed skipped], run.entries.order(:model_file_id).pluck(:outcome)
      assert_match(/Fictional failed/, run.entries.find_by!(model_file_id: malformed.id).reason)
      assert_empty ignored.reload.attachment_derivatives
      assert_equal SOURCE, part.reload.attachment.read

      ManyfoldThumbnails::BackfillJob.perform_now(run.id)
      ManyfoldThumbnails::Backfill.resume!(run_id: run.id)
      assert_equal 3, calls.length
      assert_equal 4, run.reload.scanned
    end
  end

  def test_disabled_backfill_and_regeneration_do_not_queue_or_change_files
    file = source("disabled.ipt")
    assert_raises(ManyfoldThumbnails::Backfill::Disabled) do
      ManyfoldThumbnails::Backfill.start!
    end
    assert_raises(ManyfoldThumbnails::Backfill::Disabled) do
      ManyfoldThumbnails::Backfill.regenerate!(file_id: file.id)
    end
    result = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
    assert_equal :skipped, result.outcome
    assert_empty file.reload.attachment_derivatives
  end

  def test_known_oversized_sources_are_rejected_before_downloading_or_extracting
    file = source("oversized.iam")
    file.attachment_attacher.add_metadata("size" => ManyfoldThumbnails::Catwalk::MAX_SOURCE_BYTES + 1)
    file.save!
    SiteSettings.generate_model_renders = true
    calls = []

    with_extractor({file.filename => :generated}, calls) do
      outcome = ManyfoldThumbnails::Render.new(record: file).call
      assert_equal :failed, outcome.outcome
      assert_match(/source exceeds/, outcome.reason)
    end
    assert_empty calls
    assert_empty file.reload.attachment_derivatives
  end

  def test_queued_regeneration_reports_a_deleted_source_as_skipped
    file = source("deleted.ipt")
    SiteSettings.generate_model_renders = true
    run = keep(ManyfoldThumbnails::Backfill.regenerate!(file_id: file.id))
    file.destroy!
    finish(run)
    assert_equal 1, run.reload.scanned
    assert_equal 1, run.skipped
    assert_match(/deleted before processing/, run.entries.first.reason)
  end

  def test_real_extractor_backfills_and_regenerates_an_existing_source
    image = InventorFixture.png
    bytes = InventorFixture.compound(streams: {"\u0005preview" => InventorFixture.property_set(image: image)})
    file = source("real-workflow.iam", bytes: bytes)
    SiteSettings.generate_model_renders = true
    run = keep(ManyfoldThumbnails::Backfill.start!(library_id: @library.id))
    finish(run)
    assert_equal 1, run.reload.generated
    previous_png = file.reload.attachment(:render).read
    assert_equal [512, 512], previous_png.byteslice(16, 8).unpack("NN")
    assert_equal file.id, @model.reload.preview_file_id
    assert_equal bytes, file.attachment.read

    replacement_image = InventorFixture.png(color: [0, 255, 0, 128])
    replacement = InventorFixture.compound(streams: {"\u0005preview" => InventorFixture.property_set(image: replacement_image)})
    File.binwrite(File.join(@directory, @model.path, file.filename), replacement)
    # A previous full read leaves Shrine's source IO at EOF. Regeneration must
    # reopen it instead of downloading an empty stream from that position.
    regenerated = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
    assert_equal :generated, regenerated.outcome
    replacement_png = file.reload.attachment(:render).read
    assert_equal [512, 512], replacement_png.byteslice(16, 8).unpack("NN")
    refute_equal previous_png, replacement_png
    assert_equal replacement, file.attachment.read
  end

  def test_catwalk_backfill_includes_new_extensions_and_ignores_unsupported_mime_aliases
    drawing = source("drawing.LBRN2", bytes: CatwalkFixture::LIGHTBURN)
    cloud = source("cloud.pcd", bytes: CatwalkFixture::PCD)
    mesh = source("mesh.obj", bytes: CatwalkFixture::OBJ)
    unsupported = source("legacy.lyt")
    source("assembly.f3z")
    # A library indexed before this format was registered has stale metadata.
    cloud.attachment_attacher.add_metadata("mime_type" => "application/octet-stream")
    cloud.save!
    assert_equal [drawing.id, cloud.id],
      ManyfoldThumbnails::Backfill.supported_scope.where(model: @model).order(:id).pluck(:id)

    SiteSettings.generate_model_renders = true
    run = keep(ManyfoldThumbnails::Backfill.start!(library_id: @library.id))
    finish(run)
    assert_equal 2, run.reload.generated
    assert_equal 2, run.scanned
    # Core prefers a browser-renderable mesh over the drawing's stored image.
    assert_equal mesh.id, @model.reload.preview_file_id
    [drawing, cloud].each { |file| assert file.reload.has_render? }
    refute mesh.reload.has_render?
    refute unsupported.reload.has_render?
  end

  def test_catwalk_regeneration_failure_preserves_render_and_success_refreshes_cache
    file = source("cloud.pcd", bytes: CatwalkFixture::PCD)
    SiteSettings.generate_model_renders = true
    assert_equal :generated, ManyfoldThumbnails::Render.new(record: file).call.outcome
    file.reload
    previous = file.attachment(:render)
    previous_png = previous.read
    old_key = file.cache_key_with_version
    File.binwrite(File.join(@directory, @model.path, file.filename), "invalid point cloud")
    failed = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
    assert_equal :failed, failed.outcome
    assert_equal previous_png, file.reload.attachment(:render).read
    assert_equal old_key, file.cache_key_with_version

    File.binwrite(File.join(@directory, @model.path, file.filename), CatwalkFixture::PCD)
    assert_equal :generated, ManyfoldThumbnails::Render.new(record: file, regenerate: true).call.outcome
    refute_equal old_key, file.reload.cache_key_with_version
    refute previous.exists?
  end

  def test_core_formats_require_an_explicit_override_for_plugin_backfill_and_regeneration
    mesh = source("mesh.obj", bytes: CatwalkFixture::OBJ)
    SiteSettings.generate_model_renders = true
    assert_empty ManyfoldThumbnails::Backfill.supported_scope.where(id: mesh.id)
    assert_raises(ActiveRecord::RecordNotFound) do
      ManyfoldThumbnails::Backfill.regenerate!(file_id: mesh.id)
    end
    skipped = ManyfoldThumbnails::Render.new(record: mesh, regenerate: true).call
    assert_equal :skipped, skipped.outcome
    refute mesh.reload.has_render?

    ManyfoldThumbnails::Configuration.update!(enabled_mime_types: [Mime[:obj].to_s])
    assert_equal [mesh.id], ManyfoldThumbnails::Backfill.supported_scope.where(id: mesh.id).pluck(:id)
    run = keep(ManyfoldThumbnails::Backfill.start!(library_id: @library.id))
    finish(run)
    assert_equal 1, run.reload.generated
    assert mesh.reload.has_render?

    previous_render = mesh.attachment(:render).id
    run = keep(ManyfoldThumbnails::Backfill.regenerate!(file_id: mesh.id))
    finish(run)
    assert_equal 1, run.reload.generated
    refute_equal previous_render, mesh.reload.attachment(:render).id

    ManyfoldThumbnails::Configuration.reset!
    assert_empty ManyfoldThumbnails::Backfill.supported_scope.where(id: mesh.id)
    assert_equal :skipped, ManyfoldThumbnails::Render.new(record: mesh, regenerate: true).call.outcome
  end

  def test_disabled_gap_format_is_excluded_from_backfill_and_regeneration
    cloud = source("cloud.pcd", bytes: CatwalkFixture::PCD)
    drawing = source("drawing.lbrn2", bytes: CatwalkFixture::LIGHTBURN)
    SiteSettings.generate_model_renders = true
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types:
      ManyfoldThumbnails::Configuration.enabled_mime_types - [Mime[:pcd].to_s])
    assert_equal [drawing.id], ManyfoldThumbnails::Backfill.supported_scope.where(model: @model).pluck(:id)
    assert_equal :skipped, ManyfoldThumbnails::Render.new(record: cloud, regenerate: true).call.outcome
    assert_raises(ActiveRecord::RecordNotFound) do
      ManyfoldThumbnails::Backfill.regenerate!(file_id: cloud.id)
    end
    run = keep(ManyfoldThumbnails::Backfill.start!(library_id: @library.id))
    finish(run)
    assert_equal 1, run.reload.generated
    assert drawing.reload.has_render?
    refute cloud.reload.has_render?
  end

  def test_disabling_a_format_keeps_its_existing_render_and_cache_version
    file = source("existing.pcd", bytes: CatwalkFixture::PCD)
    add_derivatives(file, render: PNG)
    original_render = file.reload.attachment(:render).data.deep_dup
    original_key = file.cache_key_with_version
    SiteSettings.generate_model_renders = true
    ManyfoldThumbnails::Configuration.update!(enabled_mime_types:
      ManyfoldThumbnails::Configuration.enabled_mime_types - [Mime[:pcd].to_s])

    assert_equal :skipped, ManyfoldThumbnails::Render.new(record: file, regenerate: true).call.outcome
    assert_equal original_render, file.reload.attachment(:render).data
    assert_equal original_key, file.cache_key_with_version
    assert_equal PNG, file.attachment(:render).read
  end

  def test_regeneration_retains_good_render_on_missing_and_malformed_images
    file = source("existing.ipt")
    add_derivatives(file, render: PNG, preview: "unrelated derivative")
    before = file.reload.attachment_data.deep_dup
    SiteSettings.generate_model_renders = true
    %i[missing_image failed].each do |status|
      with_extractor({file.filename => status}) do
        run = keep(ManyfoldThumbnails::Backfill.regenerate!(file_id: file.id))
        finish(run)
        assert_equal 1, run.reload.public_send(status)
      end
      assert_equal before, file.reload.attachment_data
      assert_equal PNG, file.attachment(:render).read
      assert_equal "unrelated derivative", file.attachment(:preview).read
      assert_equal SOURCE, file.attachment.read
    end
  end

  def test_regeneration_uploads_to_a_new_location_and_preserves_other_derivatives_and_preview_choice
    file = source("existing.iam")
    chosen = source("chosen.ipt")
    add_derivatives(file, render: "previous usable preview", preview: "unrelated derivative")
    @model.update!(preview_file: chosen)
    old_render = file.reload.attachment(:render)
    other = file.attachment(:preview).data.deep_dup
    SiteSettings.generate_model_renders = true

    with_extractor({file.filename => :generated}) do
      run = keep(ManyfoldThumbnails::Backfill.regenerate!(file_id: file.id))
      finish(run)
      assert_equal 1, run.reload.generated
    end

    updated = file.reload.attachment(:render)
    refute_equal old_render.id, updated.id
    assert_equal PNG, updated.read
    assert_equal "image/png", updated.mime_type
    assert_equal @library.storage_key, updated.storage_key
    assert updated.id.end_with?(".png")
    refute old_render.exists?
    assert_equal other, file.attachment(:preview).data
    assert_equal chosen.id, @model.reload.preview_file_id
    assert_equal SOURCE, file.attachment.read
  end

  def test_persistence_failure_keeps_old_render_and_removes_new_upload
    file = source("database-failure.ipt")
    add_derivatives(file, render: "previous usable preview", preview: "unrelated derivative")
    before = file.reload.attachment_data.deep_dup
    original_files = Dir.glob(File.join(@directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
    SiteSettings.generate_model_renders = true

    with_extractor({file.filename => :generated}) do
      with_method_stub(file, :save!, ->(**_options) { raise ActiveRecord::StatementInvalid, "Fictional persistence failure" }) do
        outcome = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
        assert_equal :failed, outcome.outcome
      end
    end

    assert_equal before, file.reload.attachment_data
    assert_equal "previous usable preview", file.attachment(:render).read
    assert_equal original_files,
      Dir.glob(File.join(@directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
  end

  def test_object_backed_sources_are_downloaded_and_derivatives_use_the_same_library_storage
    file = source("remote.ipt")
    memory = Shrine::Storage::Memory.new
    memory.upload(StringIO.new(SOURCE), file.attachment.id)
    resolvers = ModelFileUploader.opts.fetch(:dynamic_storage).fetch(:resolvers)
    resolver_key = resolvers.keys.find { |pattern| @library.storage_key.to_s.match?(pattern) }
    original_resolver = resolvers.fetch(resolver_key)
    library_id = @library.id
    resolvers[resolver_key] = lambda do |match|
      (match[1].to_i == library_id) ? memory : original_resolver.call(match)
    end
    SiteSettings.generate_model_renders = true

    with_extractor({file.filename => :generated}) do
      result = ManyfoldThumbnails::Render.new(record: file).call
      assert_equal :generated, result.outcome
    end

    file.reload
    assert_equal PNG, file.attachment(:render).read
    assert_equal @library.storage_key, file.attachment(:render).storage_key
    assert_equal SOURCE, file.attachment.read
    assert memory.exists?(file.attachment(:render).id)
    assert memory.exists?(file.attachment.id)
  ensure
    resolvers[resolver_key] = original_resolver if original_resolver
  end

  def test_outer_transaction_rollback_keeps_old_render_and_removes_uncommitted_upload
    file = source("interrupted.ipt")
    add_derivatives(file, render: "previous usable preview")
    before = file.reload.attachment_data.deep_dup
    original_files = Dir.glob(File.join(@directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
    old_render = file.attachment(:render)
    SiteSettings.generate_model_renders = true

    with_extractor({file.filename => :generated}) do
      ModelFile.transaction do
        outcome = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
        assert_equal :generated, outcome.outcome
        assert old_render.exists?, "The old image must survive until the outer transaction commits."
        raise ActiveRecord::Rollback
      end
    end

    assert_equal before, file.reload.attachment_data
    assert_equal "previous usable preview", file.attachment(:render).read
    assert_equal original_files,
      Dir.glob(File.join(@directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
  end

  def test_regeneration_uses_new_source_bytes_and_existing_render_requires_explicit_regeneration
    file = source("replaced.iam")
    add_derivatives(file, render: "old source render")
    File.binwrite(File.join(@directory, @model.path, file.filename), "Replacement Inventor source")
    file.refresh_metadata!
    file.check_derivatives!
    assert_equal "old source render", file.reload.attachment(:render).read
    SiteSettings.generate_model_renders = true
    calls = []

    with_extractor({file.filename => :generated}, calls, expected_source: "Replacement Inventor source") do
      skipped = ManyfoldThumbnails::Render.new(record: file).call
      assert_equal :skipped, skipped.outcome
      assert_equal "old source render", file.reload.attachment(:render).read
      result = ManyfoldThumbnails::Render.new(record: file, regenerate: true).call
      assert_equal :generated, result.outcome
    end
    assert_equal [file.filename], calls
    assert_equal "Replacement Inventor source", file.reload.attachment.read
  end

  private

  def keep(run)
    @runs << run
    run
  end

  def source(filename, bytes: SOURCE)
    File.binwrite(File.join(@directory, @model.path, filename), bytes)
    @model.model_files.create!(filename: filename)
  end

  def add_derivatives(file, derivatives)
    file.attachment_attacher.add_derivatives(derivatives.transform_values { |bytes| StringIO.new(bytes) })
    file.save!
  end

  def finish(run)
    10.times do
      break if run.reload.state == "completed"
      ManyfoldThumbnails::BackfillJob.perform_now(run.id)
    end
    assert_equal "completed", run.reload.state
  end

  def with_extractor(statuses, calls = [], expected_source: SOURCE)
    factory = ->(file:, record:) do
      assert_equal expected_source, File.binread(file.path)
      calls << record.filename
      FakeExtractor.new(statuses.fetch(record.filename), PNG)
    end
    with_method_stub(ManyfoldThumbnails::Catwalk, :new, factory) { yield }
  end

  def with_method_stub(object, name, implementation)
    singleton = object.singleton_class
    original = object.method(name)
    own_method = singleton.instance_methods(false).include?(name)
    singleton.send(:define_method, name) do |*arguments, **options, &block|
      implementation.call(*arguments, **options, &block)
    end
    yield
  ensure
    own_method ? singleton.send(:define_method, name, original) : singleton.send(:remove_method, name)
  end

  class FakeExtractor
    attr_reader :status, :reason

    def initialize(status, png)
      @status = status
      @reason = "Fictional #{status} diagnostic."
      @png = png
    end

    def call
      (@status == :generated) ? {render: StringIO.new(@png)} : {}
    end
  end
end
