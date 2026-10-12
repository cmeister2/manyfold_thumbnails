# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "rbconfig"
require_relative "support/inventor_fixture"
require_relative "../lib/manyfold_thumbnails/catwalk"

class CatwalkThumbnailTest < Minitest::Test
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
    assert_equal ["--output", "-", "--size", "512", "--transparent"], argv.drop(1)
    refute File.exist?(argv.first), "Temporary source must be removed after rendering"
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
end
