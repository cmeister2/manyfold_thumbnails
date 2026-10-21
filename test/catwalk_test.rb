# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rbconfig"
require "digest"
require_relative "support/inventor_fixture"
require_relative "support/temporary_method"
require_relative "../lib/manyfold_thumbnails/catwalk"

class CatwalkThumbnailTest < Minitest::Test
  include TemporaryMethod

  Record = Struct.new(:filename)

  def setup
    @directory = Dir.mktmpdir("manyfold-catwalk-test-")
    @original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
  end

  def teardown
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = @original_binary
    FileUtils.remove_entry(@directory)
  end

  def executable(body)
    path = File.join(@directory, "fake-catwalk")
    File.write(path, "#!#{RbConfig.ruby}\n#{body}\n")
    File.chmod(0o755, path)
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = path
  end

  def provider(source: "solid fixture", filename: "part.stl", klass: ManyfoldThumbnails::Catwalk)
    klass.new(file: StringIO.new(source), record: Record.new(filename))
  end

  def limited_class(**limits)
    Class.new(ManyfoldThumbnails::Catwalk).tap do |klass|
      limits.each { |constant, value| klass.const_set(constant, value) }
    end
  end

  def test_streamed_input_restores_extension_and_arguments_without_a_shell
    arguments = File.join(@directory, "arguments")
    input_data = File.join(@directory, "input-data")
    png = InventorFixture.png(width: 512, height: 512)
    executable <<~RUBY
      File.write(#{arguments.dump}, ARGV.join("\n"))
      File.binwrite(#{input_data.dump}, File.binread(ARGV.first))
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    extractor = provider(filename: "part; touch unexpected.STL")
    render = extractor.call.fetch(:render)
    assert_equal :generated, extractor.status
    assert_equal png, render.read
    assert_equal "solid fixture", File.binread(input_data)
    argv = File.read(arguments).lines.map(&:chomp)
    assert_equal ".stl", File.extname(argv.first)
    assert_equal ["--output", "-", "--resolution", "512,512", "--transparent"], argv.drop(1)
    refute File.exist?(argv.first), "Temporary source must be removed after rendering"
  end

  def test_older_hosts_without_a_resolution_setting_keep_the_default
    png = InventorFixture.png(width: 512, height: 512)
    executable "$stdout.binmode; $stdout.write(#{png.dump})"
    [nil, Object.new].each do |settings|
      with_site_settings(settings) do
        extractor = provider
        assert_equal png, extractor.call.fetch(:render).read
        assert_equal :generated, extractor.status
      end
    end
  end

  def test_supported_resolutions_and_rectangular_bounds_are_passed_to_catwalk
    arguments = File.join(@directory, "arguments")
    dimensions = [128, 256, 512, 1024, 2048].map { |size| [size, size] } + [[1, 4096], [4096, 1]]
    dimensions.each do |width, height|
      png = InventorFixture.png(width: width, height: height)
      executable <<~RUBY
        File.write(#{arguments.dump}, ARGV.join("\n"))
        $stdout.binmode
        $stdout.write(#{png.dump})
      RUBY
      settings = Struct.new(:model_renders_size).new("#{width},#{height}")
      with_site_settings(settings) do
        extractor = provider
        assert_equal png, extractor.call.fetch(:render).read
        assert_equal :generated, extractor.status
      end
      assert_equal ["--output", "-", "--resolution", "#{width},#{height}", "--transparent"],
        File.readlines(arguments, chomp: true).drop(1)
    end
  end

  def test_resolution_is_read_once_per_call_and_changes_are_applied_to_the_same_provider
    reads = 0
    settings = Object.new
    settings.define_singleton_method(:model_renders_size) do
      reads += 1
      reads == 1 ? "128,256" : "256,128"
    end
    with_site_settings(settings) do
      extractor = provider
      [[128, 256], [256, 128]].each_with_index do |(width, height), index|
        png = InventorFixture.png(width: width, height: height)
        executable "$stdout.binmode; $stdout.write(#{png.dump})"
        assert_equal png, extractor.call.fetch(:render).read
        assert_equal :generated, extractor.status
        assert_equal index + 1, reads
      end
    end
  end

  def test_high_resolution_png_can_exceed_the_default_output_limit
    width = height = 2048
    random = Random.new(123)
    scanlines = Array.new(height) { "\0".b + random.bytes(width * 4) }.join
    png = ManyfoldThumbnails::Catwalk::PNG_SIGNATURE +
      InventorFixture.chunk("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNC5")) +
      InventorFixture.chunk("IDAT", Zlib.deflate(scanlines)) + InventorFixture.chunk("IEND", "".b)
    assert_operator png.bytesize, :>, ManyfoldThumbnails::Catwalk::MAX_OUTPUT_BYTES
    path = File.join(@directory, "high-resolution.png")
    File.binwrite(path, png)
    executable "$stdout.binmode; IO.copy_stream(#{path.dump}, $stdout)"
    with_site_settings(Struct.new(:model_renders_size).new("2048,2048")) do
      extractor = provider
      render = extractor.call.fetch(:render)
      assert_equal :generated, extractor.status
      assert_equal Digest::SHA256.hexdigest(png), Digest::SHA256.hexdigest(render.read)
    end
  end

  def test_wrong_output_dimensions_are_rejected_including_swapped_rectangles
    with_site_settings(Struct.new(:model_renders_size).new("128,256")) do
      [[512, 512], [256, 128], [128, 128], [256, 256]].each do |width, height|
        png = InventorFixture.png(width: width, height: height)
        executable "$stdout.binmode; $stdout.write(#{png.dump})"
        extractor = provider
        assert_empty extractor.call
        assert_equal :failed, extractor.status
        assert_includes extractor.reason, "128 x 256 PNG"
      end
    end
  end

  def test_invalid_resolutions_fail_before_launching_catwalk
    forbidden = lambda { raise "An invalid resolution must not resolve the executable" }
    with_temporary_method(ManyfoldThumbnails::Executable, :path, forbidden) do
      [nil, "", "512", "512x512", "512,512,512", "128.5,256", "-1,512", "0,512",
        "512,0", "4097,512", "512,4097", "512,512; touch unexpected", [512, 512]].each do |value|
        with_site_settings(Struct.new(:model_renders_size).new(value)) do
          extractor = provider
          assert_empty extractor.call, value.inspect
          assert_equal :failed, extractor.status, value.inspect
          assert_includes extractor.reason.downcase, "resolution"
        end
      end
    end
  end

  def test_local_input_keeps_parent_directory_and_source_bytes
    arguments = File.join(@directory, "arguments")
    png = InventorFixture.png(width: 512, height: 512)
    executable "File.write(#{arguments.dump}, ARGV.first); $stdout.binmode; $stdout.write(#{png.dump})"
    source = File.join(@directory, "model; safe.obj")
    File.binwrite(source, "model source")
    File.open(source, "rb") do |file|
      extractor = ManyfoldThumbnails::Catwalk.new(file: file, record: Record.new("model; safe.obj"))
      assert extractor.call[:render]
      assert_equal 0, file.pos
    end
    assert_equal source, File.read(arguments)
    assert_equal "model source", File.binread(source)
  end

  def test_model_assembly_materializes_named_companions_for_catwalk_and_cleans_up
    arguments = File.join(@directory, "arguments")
    staged_bytes = File.join(@directory, "staged-bytes")
    png = InventorFixture.png(width: 128, height: 256)
    reads = 0
    settings = Object.new
    settings.define_singleton_method(:model_renders_size) { reads += 1; "128,256" }
    executable <<~RUBY
      File.open(#{arguments.dump}, "a") { |file| file.puts ARGV.drop(1).join(" ") }
      exit 3 unless File.basename(ARGV.first) == "Main.IAM"
      primary = File.binread(ARGV.first)
      companion = File.binread(File.join(File.dirname(ARGV.first), "Part.IPT"))
      File.binwrite(#{staged_bytes.dump}, ARGV.first + "\n" + primary + "|" + companion)
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    record_class = Struct.new(:id, :filename, :attachment, :model)
    model = Struct.new(:model_files).new([])
    companion_attachment = Object.new
    companion_attachment.define_singleton_method(:size) { "object storage part".bytesize }
    companion_attachment.define_singleton_method(:open) do |&block|
      StringIO.open("object storage part", &block)
    end
    record = record_class.new(1, "Main.IAM", nil, model)
    model.model_files = [record, record_class.new(2, "Part.IPT", companion_attachment, model)]
    source = File.join(@directory, "shrine-random.iam")
    File.binwrite(source, "isolated assembly")
    with_site_settings(settings) do
      File.open(source, "rb") do |file|
        extractor = ManyfoldThumbnails::Catwalk.new(file: file, record: record)
        assert_equal png, extractor.call.fetch(:render).read
        assert_equal :generated, extractor.status
        assert_equal 0, file.pos
      end
    end
    path, bytes = File.binread(staged_bytes).split("\n", 2)
    assert_equal "isolated assembly|object storage part", bytes
    assert_equal "Main.IAM", File.basename(path)
    refute_equal source, path
    assert_equal ["--output - --resolution 128,256 --transparent"] * 2, File.readlines(arguments, chomp: true)
    assert_equal 1, reads, "Assembly retries must reuse the resolution read for the initial call."
    refute File.exist?(File.dirname(path)), "Staged project must be removed after Catwalk exits"
    assert_equal "isolated assembly", File.binread(source)
  end

  def test_invalid_model_assembly_project_is_reported_after_the_ordinary_call_fails
    observation = File.join(@directory, "ordinary-input")
    executable "File.write(#{observation.dump}, ARGV.first); exit 3"
    model = Struct.new(:model_files).new([])
    record = Struct.new(:filename, :model).new("../Main.iam", model)
    extractor = ManyfoldThumbnails::Catwalk.new(file: StringIO.new("assembly"), record: record)
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "relative paths"
    assert_equal ".iam", File.extname(File.read(observation))
  end

  def test_usable_saved_assembly_thumbnail_ignores_unused_companion_problems
    invocations = File.join(@directory, "invocations")
    png = InventorFixture.png(width: 512, height: 512)
    executable <<~RUBY
      File.open(#{invocations.dump}, "a") { |file| file.puts ARGV.first }
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    record_class = Struct.new(:id, :filename, :attachment, :model)
    unusable_attachment = Object.new
    unusable_attachment.define_singleton_method(:size) { 512 * 1024 * 1024 }
    unusable_attachment.define_singleton_method(:open) { |*| raise "Unused companions must not be downloaded" }
    [
      ["duplicate.ipt", "DUPLICATE.ipt"],
      ["../outside.ipt"],
      Array.new(128) { |index| "part-#{index}.ipt" },
      ["oversized.ipt"]
    ].each do |filenames|
      records = filenames.each_with_index.map { |name, index| record_class.new(index + 2, name, unusable_attachment) }
      inspections = 0
      model = Object.new
      model.define_singleton_method(:model_files) { inspections += 1; records }
      record = record_class.new(1, "Main.iam", nil, model)
      extractor = ManyfoldThumbnails::Catwalk.new(file: StringIO.new("saved assembly preview"), record: record)
      assert_equal png, extractor.call.fetch(:render).read
      assert_equal :generated, extractor.status
      assert_equal 0, inspections, "Saved thumbnails must not inspect unused companions."
    end
    assert_equal 4, File.readlines(invocations).length, "A usable thumbnail needs only one Catwalk invocation."
  end

  def test_successful_local_assembly_uses_its_existing_directory_without_staging
    observation = File.join(@directory, "ordinary-input")
    png = InventorFixture.png(width: 512, height: 512)
    executable "File.write(#{observation.dump}, ARGV.first); $stdout.binmode; $stdout.write(#{png.dump})"
    model = Object.new
    model.define_singleton_method(:model_files) { raise "Successful local input must not stage companions" }
    record = Struct.new(:filename, :model).new("Main.iam", model)
    source = File.join(@directory, "Main.iam")
    File.binwrite(source, "existing project assembly")
    File.open(source, "rb") do |file|
      extractor = ManyfoldThumbnails::Catwalk.new(file: file, record: record)
      assert_equal png, extractor.call.fetch(:render).read
      assert_equal :generated, extractor.status
    end
    assert_equal source, File.read(observation)
  end

  def test_assembly_retry_shares_the_initial_processing_deadline
    invocations = File.join(@directory, "invocations")
    png = InventorFixture.png(width: 512, height: 512)
    executable <<~RUBY
      File.open(#{invocations.dump}, "a") { |file| file.puts ARGV.first }
      sleep 2
      exit 3 unless File.basename(ARGV.first) == "Main.iam"
      $stdout.binmode
      $stdout.write(#{png.dump})
    RUBY
    model = Struct.new(:model_files).new([])
    record = Struct.new(:filename, :model).new("Main.iam", model)
    extractor = limited_class(MAX_SECONDS: 3).new(file: StringIO.new("assembly"), record: record)
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "processing limit"
    assert_equal 2, File.readlines(invocations).length
  end

  def test_unsupported_mime_aliases_do_not_launch_catwalk
    executable "abort 'must not launch'"
    %w[project.f3z scene.lyt document.bin photo.png].each do |filename|
      extractor = provider(filename: filename)
      assert_empty extractor.call
      assert_equal :missing_image, extractor.status
      refute ManyfoldThumbnails::Formats.supported?(Record.new(filename))
      assert_nil ManyfoldThumbnails::Formats.thumbnailer_for(Record.new(filename))
    end
  end

  def test_supported_document_without_saved_image_is_missing_image
    executable "$stderr.write('catwalk: document contains no supported saved preview'); exit 3"
    extractor = provider(filename: "project.f3d")
    assert_empty extractor.call
    assert_equal :missing_image, extractor.status
    assert_includes extractor.reason, "no supported saved preview"
  end

  def test_failed_decoder_and_invalid_output_do_not_produce_derivatives
    executable "$stderr.binmode; $stderr.write(\"invalid input\\xff\".b); exit 1"
    extractor = provider
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert extractor.reason.valid_encoding?
    assert_includes extractor.reason, "invalid input"

    executable "$stdout.write('not a PNG')"
    extractor = provider
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "512 x 512 PNG"

    png = InventorFixture.png
    executable "$stdout.binmode; $stdout.write(#{png.dump})"
    extractor = provider
    assert_empty extractor.call
    assert_equal :failed, extractor.status
  end

  def test_source_limit_is_checked_before_source_is_read
    source = Object.new
    source.define_singleton_method(:size) { ManyfoldThumbnails::Catwalk::MAX_SOURCE_BYTES + 1 }
    source.define_singleton_method(:read) { |*| raise "Source must not be read" }
    extractor = ManyfoldThumbnails::Catwalk.new(file: source, record: Record.new("part.stl"))
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "processing limit"
  end

  def test_copy_limit_rejects_a_stream_that_misreports_size
    source = StringIO.new("a" * 33)
    source.define_singleton_method(:size) { 1 }
    extractor = limited_class(MAX_SOURCE_BYTES: 32).new(file: source, record: Record.new("part.stl"))
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_equal 0, source.pos
  end

  def test_output_and_diagnostic_limits_stop_noisy_processes
    [["$stdout", :MAX_OUTPUT_BYTES], ["$stderr", :MAX_ERROR_BYTES]].each do |stream, constant|
      executable "#{stream}.write('a' * 8192); #{stream}.flush; sleep 20"
      extractor = provider(klass: limited_class(constant => 1024))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_empty extractor.call
      assert_equal :failed, extractor.status
      assert_includes extractor.reason, "output limit"
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end
  end

  def test_deadline_kills_a_process_group_even_after_its_parent_exits
    child_file = File.join(@directory, "child-pid")
    executable <<~RUBY
      child = fork { sleep 20 }
      File.write(#{child_file.dump}, child.to_s)
      exit! 0
    RUBY
    extractor = provider(klass: limited_class(MAX_SECONDS: 0.5))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "processing limit"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    child = File.read(child_file).to_i
    # A reparented child may briefly remain as a zombie until PID 1 reaps it.
    stat = "/proc/#{child}/stat"
    running = lambda do
      File.read(stat).split[2] != "Z"
    rescue Errno::ENOENT
      false
    end
    100.times do
      break unless running.call

      sleep 0.01
    end
    refute running.call, "Timed-out child must not continue running"
  end

  def test_missing_executable_reports_failure
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = File.join(@directory, "missing")
    extractor = provider
    assert_empty extractor.call
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "missing"
  end

  def test_download_failure_reports_failure_without_a_derivative
    failure = lambda { raise ManyfoldThumbnails::Executable::DownloadError, "GitHub download timed out" }
    with_temporary_method(ManyfoldThumbnails::Executable, :path, failure) do
      extractor = provider(filename: "drawing.lbrn2")
      assert_empty extractor.call
      assert_equal :failed, extractor.status
      assert_includes extractor.reason, "GitHub download timed out"
    end
  end

  def test_unsupported_or_empty_source_does_not_trigger_a_download
    forbidden = lambda { raise "A rejected source must not trigger a download" }
    with_temporary_method(ManyfoldThumbnails::Executable, :path, forbidden) do
      extractor = provider(filename: "unsupported.bin")
      assert_empty extractor.call
      assert_equal :missing_image, extractor.status

      extractor = provider(source: "", filename: "drawing.lbrn2")
      assert_empty extractor.call
      assert_equal :failed, extractor.status
      assert_includes extractor.reason, "empty"
    end
  end

  private

  def with_site_settings(settings)
    original = Object.const_get(:SiteSettings) if Object.const_defined?(:SiteSettings)
    Object.send(:remove_const, :SiteSettings) if original
    Object.const_set(:SiteSettings, settings) if settings
    yield
  ensure
    Object.send(:remove_const, :SiteSettings) if Object.const_defined?(:SiteSettings)
    Object.const_set(:SiteSettings, original) if original
  end
end
