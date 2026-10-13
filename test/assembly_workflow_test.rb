# frozen_string_literal: true

require "rbconfig"

# These exercise Manyfold's actual automatic Shrine download and storage APIs.
# Native qualification additionally accepts a mounted Catwalk build and the
# genuine MIT conveyor project retained by Catwalk's integration fixtures.
class ThumbnailsPluginTest
  def test_assembly_companions_are_staged_during_normal_background_promotion
    qualify_assembly_workflow(model: @model)
  end

  def test_assembly_companions_are_staged_from_object_storage
    with_assembly_object_library do |model, memory|
      assembly = qualify_assembly_workflow(model: model)
      assert memory.exists?(assembly.attachment(:render).id)
      assert memory.exists?(assembly.attachment.id)
    end
  end

  def test_native_assembly_background_promotion_renders_genuine_conveyor_geometry
    with_native_assembly_runtime do |fixture_directory|
      qualify_native_conveyor(model: @model, fixture_directory: fixture_directory)
    end
  end

  def test_native_assembly_object_storage_renders_genuine_conveyor_geometry
    with_native_assembly_runtime do |fixture_directory|
      with_assembly_object_library do |model, memory|
        assembly = qualify_native_conveyor(model: model, fixture_directory: fixture_directory)
        assert memory.exists?(assembly.attachment(:render).id)
      end
    end
  end

  private

  def qualify_assembly_workflow(model:)
    original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
    source = "current assembly attachment"
    companion = "original native part attachment"
    observation = File.join(@directory, "assembly-invocation")
    executable = File.join(@directory, "inspect-catwalk-input")
    png = InventorFixture.png(width: 512, height: 512)
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      exit 3 unless File.basename(ARGV.first) == "Project.IAM"
      abort "wrong assembly bytes" unless File.binread(ARGV.first) == #{source.dump}
      abort "missing original companion" unless File.binread(File.join(File.dirname(ARGV.first), "Part.IPT")) == #{companion.dump}
      File.write(#{observation.dump}, ARGV.first)
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    File.chmod(0o755, executable)
    # Companion promotion must not run the assembly-specific probe.
    SiteSettings.generate_model_renders = false
    part, = ingest(model: model, filename: "Part.IPT", source: companion)
    SiteSettings.generate_model_renders = true
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = executable
    assembly, = ingest(model: model, filename: "Project.IAM", source: source)
    assert assembly.has_render?, "Automatic promotion should see the named companion."
    assert_equal png, assembly.attachment(:render).read
    assert_equal source, assembly.attachment.read
    assert_equal companion, part.attachment.read
    staged = File.read(observation)
    assert_equal "Project.IAM", File.basename(staged)
    refute File.exist?(File.dirname(staged)), "Temporary assembly project must be removed."
    assembly
  ensure
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = original_binary
  end

  def with_assembly_object_library
    @object_library = Library.create!(name: "Remote assembly adapter test", storage_service: "s3",
      path: "fictional-object-library", s3_bucket: "fictional-local-test-bucket", s3_region: "eu-west-2",
      s3_access_key_id: "fictional-key", s3_secret_access_key: "fictional-secret",
      path_template: "{creator}/{modelName}")
    memory = Shrine::Storage::Memory.new
    resolvers = ModelFileUploader.opts.fetch(:dynamic_storage).fetch(:resolvers)
    resolver_key = resolvers.keys.find { |pattern| @object_library.storage_key.to_s.match?(pattern) }
    original_resolver = resolvers.fetch(resolver_key)
    library_id = @object_library.id
    resolvers[resolver_key] = lambda do |match|
      (match[1].to_i == library_id) ? memory : original_resolver.call(match)
    end
    model = Model.create!(name: "Remote assembly fixture", path: "remote-model", library: @object_library)
    yield model, memory
  ensure
    resolvers[resolver_key] = original_resolver if original_resolver
  end

  def with_native_assembly_runtime
    original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
    binary = ENV["MANYFOLD_THUMBNAILS_NATIVE_CATWALK"]
    fixtures = ENV["MANYFOLD_THUMBNAILS_NATIVE_INVENTOR_FIXTURES"]
    skip "Mount a native Catwalk build and its genuine Inventor conveyor fixtures to qualify geometry." unless
      binary && File.executable?(binary) && fixtures && File.file?(File.join(fixtures, "conveyor_model.iam"))

    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = binary
    yield fixtures
  ensure
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = original_binary
  end

  def qualify_native_conveyor(model:, fixture_directory:)
    original_sources = {}
    SiteSettings.generate_model_renders = false
    %w[box.ipt part.ipt rail.ipt support.ipt].each do |filename|
      source = File.binread(File.join(fixture_directory, filename))
      original_sources[filename] = source
      ingest(model: model, filename: filename, source: source)
    end
    SiteSettings.generate_model_renders = true
    filename = "conveyor_model.iam"
    source = File.binread(File.join(fixture_directory, filename))
    original_sources[filename] = source
    expected_render, diagnostic, status = Open3.capture3(ManyfoldThumbnails::Catwalk.binary,
      File.join(fixture_directory, filename), "--render-geometry", "--output", "-",
      "--size", "512", "--transparent")
    assert status.success?, "The genuine geometry fixture must render directly: #{diagnostic}"
    assembly, = ingest(model: model, filename: filename, source: source)
    assert assembly.has_render?, "Native Catwalk must render the genuine companion-backed assembly."
    render = assembly.attachment(:render)
    assert_equal "image/png", render.mime_type
    actual_render = render.read
    assert_equal [512, 512], actual_render.byteslice(16, 8).unpack("NN")
    assert_equal Digest::SHA256.hexdigest(expected_render), Digest::SHA256.hexdigest(actual_render),
      "Automatic promotion must produce Catwalk's fresh native geometry render."
    model.model_files.each do |file|
      assert_equal original_sources.fetch(file.filename), file.attachment.read,
        "Rendering must preserve each original native document."
    end
    assembly
  end
end
