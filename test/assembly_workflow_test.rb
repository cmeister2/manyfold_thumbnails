# frozen_string_literal: true

require "rbconfig"
require "json"
require "zip"
require_relative "support/solidworks_fixture"

# These exercise Manyfold's actual automatic Shrine download and storage APIs.
# Native qualification uses the pinned Catwalk release and original licensed
# documents. A mounted Catwalk build can also qualify a future source change.
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

  def test_native_part_background_promotion_renders_genuine_box_geometry
    with_native_assembly_runtime do |fixture_directory|
      filename = "box.ipt"
      path = File.join(fixture_directory, filename)
      source = File.binread(path)
      expected_render = forced_native_render(path)
      file, = ingest(filename: filename, source: source)
      assert_native_render(file, expected_render)
      assert_equal source, file.attachment.read
    end
  end

  def test_native_fusion_background_promotion_falls_back_when_saved_images_are_missing
    with_native_assembly_runtime do
      original = File.join(__dir__, "fixtures/native_geometry/fusion-toy-block.f3d")
      path = File.join(@directory, "fusion-no-images.f3d")
      retained = {}
      removed_images = []
      Zip::File.open(original) do |archive|
        Zip::OutputStream.open(path) do |output|
          archive.each do |entry|
            if entry.name.downcase.end_with?(".png")
              removed_images << entry.name
              next
            end

            bytes = entry.directory? ? "".b : entry.get_input_stream.read
            retained[entry.name] = Digest::SHA256.hexdigest(bytes)
            output.put_next_entry(entry.name)
            output.write(bytes) unless entry.directory?
          end
        end
      end
      refute_empty removed_images, "The original Fusion document must contain a saved image."
      Zip::File.open(path) do |archive|
        assert_equal retained.keys.sort, archive.entries.map(&:name).sort
        archive.each do |entry|
          bytes = entry.directory? ? "".b : entry.get_input_stream.read
          assert_equal retained.fetch(entry.name), Digest::SHA256.hexdigest(bytes),
            "Removing previews must preserve all native document members."
        end
      end
      expected_render = forced_native_render(path)
      source = File.binread(path)
      file, = ingest(filename: File.basename(path), source: source)
      assert_native_render(file, expected_render)
      assert_equal source, file.attachment.read
    end
  end

  def test_genuine_native_fixture_hashes_match_original_producer_documents
    directory = File.join(__dir__, "fixtures/native_geometry")
    records = JSON.parse(File.read(File.join(directory, "provenance.json")))
    assert_equal 6, records.length
    records.each do |record|
      path = File.join(directory, record.fetch("file"))
      assert_equal record.fetch("bytes"), File.size(path)
      assert_equal record.fetch("sha256"), Digest::SHA256.file(path).hexdigest
      assert File.file?(File.join(directory, record.fetch("license_file")))
    end
  end

  def test_solidworks_companions_during_background_promotion
    qualify_assembly_workflow(model: @model, assembly_name: "Project.SLDASM", part_name: "Part.SLDPRT")
  end

  def test_solidworks_companions_from_object_storage
    with_assembly_object_library do |model, memory|
      assembly = qualify_assembly_workflow(model: model, assembly_name: "Project.SLDASM", part_name: "Part.SLDPRT")
      assert memory.exists?(assembly.attachment(:render).id)
    end
  end

  def test_native_solidworks_background_promotion
    qualify_native_solidworks(model: @model)
  end

  def test_native_solidworks_object_storage
    with_assembly_object_library do |model, memory|
      assembly = qualify_native_solidworks(model: model)
      assert memory.exists?(assembly.attachment(:render).id)
    end
  end

  private

  def qualify_assembly_workflow(model:, assembly_name: "Project.IAM", part_name: "Part.IPT")
    original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
    source = "current assembly attachment"
    companion = "original native part attachment"
    observation = File.join(@directory, "assembly-invocation")
    executable = File.join(@directory, "inspect-catwalk-input")
    png = InventorFixture.png(width: 512, height: 512)
    File.write(executable, <<~RUBY)
      #!#{RbConfig.ruby}
      exit 3 unless File.basename(ARGV.first) == #{assembly_name.dump}
      abort "wrong assembly bytes" unless File.binread(ARGV.first) == #{source.dump}
      abort "missing original companion" unless File.binread(File.join(File.dirname(ARGV.first), #{part_name.dump})) == #{companion.dump}
      File.write(#{observation.dump}, ARGV.first)
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    File.chmod(0o755, executable)
    # Companion promotion must not run the assembly-specific probe.
    SiteSettings.generate_model_renders = false
    part, = ingest(model: model, filename: part_name, source: companion)
    SiteSettings.generate_model_renders = true
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = executable
    assembly, = ingest(model: model, filename: assembly_name, source: source)
    assert assembly.has_render?, "Automatic promotion should see the named companion."
    assert_equal png, assembly.attachment(:render).read
    assert_equal source, assembly.attachment.read
    assert_equal companion, part.attachment.read
    staged = File.read(observation)
    assert_equal assembly_name, File.basename(staged)
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
    binary = ENV["MANYFOLD_THUMBNAILS_NATIVE_CATWALK"] || ManyfoldThumbnails::Catwalk.binary
    fixtures = ENV["MANYFOLD_THUMBNAILS_NATIVE_INVENTOR_FIXTURES"] ||
      File.join(__dir__, "fixtures/native_geometry/conveyor")
    assert File.executable?(binary), "Native qualification requires the actual Catwalk executable."
    assert File.file?(File.join(fixtures, "conveyor_model.iam")), "Genuine assembly fixtures must be available."

    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = binary
    yield fixtures
  ensure
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = original_binary
  end

  def qualify_native_solidworks(model:)
    directory = SolidWorksFixture.directory
    SiteSettings.generate_model_renders = false
    Dir[File.join(directory, "*.SLDPRT")].each do |path|
      ingest(model: model, filename: File.basename(path), source: File.binread(path))
    end
    SiteSettings.generate_model_renders = true
    path = File.join(directory, "no-preview.sldasm")
    source = File.binread(path)
    expected = forced_native_render(path)
    assembly, = ingest(model: model, filename: File.basename(path), source: source)
    assert_native_render(assembly, expected)
    assert_equal source, assembly.attachment.read
    assembly
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
    expected_render = forced_native_render(File.join(fixture_directory, filename))
    assembly, = ingest(model: model, filename: filename, source: source)
    assert assembly.has_render?, "Native Catwalk must render the genuine companion-backed assembly."
    assert_native_render(assembly, expected_render)
    model.model_files.each do |file|
      assert_equal original_sources.fetch(file.filename), file.attachment.read,
        "Rendering must preserve each original native document."
    end
    assembly
  end

  def forced_native_render(path)
    render, diagnostic, status = Open3.capture3(ManyfoldThumbnails::Catwalk.binary,
      path, "--render-geometry", "--output", "-", "--size", "512", "--transparent")
    assert status.success?, "The genuine geometry fixture must render directly: #{diagnostic}"
    render
  end

  def assert_native_render(file, expected)
    assert file.has_render?, "Automatic promotion must generate a native geometry thumbnail."
    render = file.attachment(:render)
    assert_equal "image/png", render.mime_type
    actual = render.read
    assert_equal [512, 512], actual.byteslice(16, 8).unpack("NN")
    assert_equal Digest::SHA256.hexdigest(expected), Digest::SHA256.hexdigest(actual),
      "Automatic promotion must produce Catwalk's fresh native geometry render."
  end
end
