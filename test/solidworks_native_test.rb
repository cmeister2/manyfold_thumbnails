# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "open3"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../lib/manyfold_thumbnails/catwalk"
require_relative "support/solidworks_fixture"

# Genuine producer documents qualified with the pinned executable, not a mock.
class SolidWorksNativeTest < Minitest::Test
  DIRECTORY = SolidWorksFixture.directory
  METADATA = File.join(__dir__, "fixtures/native_geometry/solidworks")
  Record = Struct.new(:id, :filename, :attachment, :model)
  Model = Struct.new(:model_files)

  class Attachment
    attr_reader :opens

    def initialize(path)
      @path = path
      @opens = 0
    end

    def size = File.size(@path)

    def open(&block)
      @opens += 1
      File.open(@path, "rb", &block)
    end
  end

  def setup
    @original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
    ENV.delete("MANYFOLD_THUMBNAILS_CATWALK")
    @binary = ENV["MANYFOLD_THUMBNAILS_NATIVE_CATWALK"] || ManyfoldThumbnails::Catwalk.binary
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = @binary
    @model = Model.new([])
    Dir[File.join(DIRECTORY, "*.SLDPRT")].sort.each do |path|
      @model.model_files << Record.new(@model.model_files.length + 2, File.basename(path), Attachment.new(path), @model)
    end
    @record = Record.new(1, "no-preview.sldasm", nil, @model)
  end

  def teardown
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = @original_binary
  end

  def generate(name = "no-preview.sldasm")
    @record.filename = name
    source = File.binread(File.join(DIRECTORY, name))
    extractor = ManyfoldThumbnails::Catwalk.new(file: StringIO.new(source), record: @record)
    result = extractor.call
    [extractor, result]
  end

  def native_render
    output, diagnostic, status = Open3.capture3(@binary,
      File.join(DIRECTORY, "solidworks-powerpackage.sldasm"),
      "--render-geometry", "--output", "-", "--size", "512", "--transparent")
    assert status.success?, diagnostic
    output.b
  end

  def test_fixture_hashes_and_license
    JSON.parse(File.read(File.join(METADATA, "qualification.json"))).fetch("files").each do |file|
      assert_equal file.fetch("sha256"), Digest::SHA256.file(File.join(DIRECTORY, file.fetch("file"))).hexdigest
    end
    assert_includes File.read(File.join(METADATA, "POWER-PACKAGE-LICENSE.txt")), "Copyright (c) 2022 GuoXiong"
  end

  def test_saved_preview_never_inspects_or_downloads_companions
    @model.define_singleton_method(:model_files) { raise "Saved preview must not enumerate companions" }
    extractor, result = generate("solidworks-powerpackage.sldasm")
    assert_equal :generated, extractor.status
    refute_empty result.fetch(:render).read
  end

  def test_downloaded_assembly_matches_original_native_geometry
    extractor, result = generate
    assert_equal :generated, extractor.status, extractor.reason
    assert_equal Digest::SHA256.hexdigest(native_render), Digest::SHA256.hexdigest(result.fetch(:render).read)
    assert @model.model_files.all? { |record| record.attachment.opens == 1 }
  end

  def test_local_project_renders_without_opening_attachments
    File.open(File.join(DIRECTORY, "no-preview.sldasm"), "rb") do |source|
      extractor = ManyfoldThumbnails::Catwalk.new(file: source, record: @record)
      assert_equal Digest::SHA256.hexdigest(native_render), Digest::SHA256.hexdigest(extractor.call.fetch(:render).read)
      assert_equal :generated, extractor.status
    end
    assert @model.model_files.all? { |record| record.attachment.opens.zero? }
  end

  def test_missing_component_does_not_produce_partial_geometry
    @model.model_files.shift
    extractor, result = generate
    assert_empty result
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "missing SolidWorks companion"
  end

  def test_ambiguous_component_is_refused_before_download
    record = @model.model_files.first
    @model.model_files << Record.new(99, record.filename.downcase, record.attachment, @model)
    extractor, result = generate
    assert_empty result
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "duplicate component filenames"
    assert @model.model_files.all? { |component| component.attachment.opens.zero? }
  end

  def test_unsafe_component_is_refused_before_download
    @model.model_files.first.filename = "../escape.sldprt"
    extractor, result = generate
    assert_empty result
    assert_equal :failed, extractor.status
    assert_includes extractor.reason, "relative paths without traversal"
    assert @model.model_files.all? { |record| record.attachment.opens.zero? }
  end
end
