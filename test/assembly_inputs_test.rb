# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "support/temporary_method"
require_relative "../lib/manyfold_thumbnails/assembly_inputs"

class AssemblyInputsTest < Minitest::Test
  include TemporaryMethod

  Model = Struct.new(:model_files)
  Record = Struct.new(:id, :filename, :attachment, :model)

  class Attachment
    attr_reader :opens, :closes

    def initialize(bytes, declared_size: bytes.bytesize, delay: 0)
      @bytes, @declared_size, @delay = bytes, declared_size, delay
      @opens = @closes = 0
    end

    def size
      @declared_size
    end

    def open
      @opens += 1
      source = StringIO.new(@bytes)
      sleep @delay if @delay.positive?
      yield source
    ensure
      source.close
      @closes += 1
    end
  end

  def setup
    @source = StringIO.new("current primary bytes")
    @model = Model.new([])
    @record = Record.new(1, "Main.IAM", Attachment.new("old attachment bytes"), @model)
    @model.model_files << @record
    @staged_directory = nil
  end

  def teardown
    refute File.exist?(@staged_directory), "Staged project must be cleaned up" if @staged_directory
  end

  def add(filename, bytes = "native companion", **options)
    attachment = Attachment.new(bytes, **options)
    Record.new(@model.model_files.length + 1, filename, attachment, @model).tap { @model.model_files << it }
  end

  def stage(klass: ManyfoldThumbnails::AssemblyInputs, seconds: 5, &block)
    original = Dir.method(:mktmpdir)
    test = self
    capture = lambda do |*arguments, &callback|
      original.call(*arguments) do |directory|
        test.instance_variable_set(:@staged_directory, directory)
        callback.call(directory)
      end
    end
    with_temporary_method(Dir, :mktmpdir, capture) do
      klass.new(file: @source, record: @record,
        deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds).with_files(&block)
    end
  end

  def limited_class(**limits)
    Class.new(ManyfoldThumbnails::AssemblyInputs).tap do |klass|
      limits.each { |name, value| klass.const_set(name, value) }
    end
  end

  def test_current_primary_and_remote_companions_keep_original_case_and_paths
    @record.filename = "Assembly/Main.IAM"
    part = add("Assembly/Part.IPT", "remote part bytes")
    child = add("Assembly/Subgroup/Child.iam", "remote assembly bytes")
    image = add("unrelated.png", "unrelated image")
    @source.read(3)
    result = stage do |input|
      assert_equal File.join(@staged_directory, "Assembly/Main.IAM"), input
      assert_equal "current primary bytes", File.binread(input)
      assert_equal "remote part bytes", File.binread(File.join(@staged_directory, part.filename))
      assert_equal "remote assembly bytes", File.binread(File.join(@staged_directory, child.filename))
      refute File.exist?(File.join(@staged_directory, image.filename))
      :rendered
    end
    assert_equal :rendered, result
    assert_equal 0, @record.attachment.opens, "Primary must use the provided source snapshot"
    assert_equal 0, image.attachment.opens
    assert_equal 1, part.attachment.opens
    assert_equal 1, part.attachment.closes
    assert_equal 0, @source.pos
  end

  def test_isolated_shrine_tempfile_is_copied_to_the_original_assembly_name
    Dir.mktmpdir("shrine-original-") do |directory|
      original = File.join(directory, "shrine-random.iam")
      File.binwrite(original, "isolated original")
      File.open(original, "rb") do |source|
        @source = source
        add("Part.ipt", "named companion")
        stage do |input|
          refute_equal original, input
          assert_equal "Main.IAM", File.basename(input)
          assert_equal "isolated original", File.binread(input)
          assert_equal "named companion", File.binread(File.join(File.dirname(input), "Part.ipt"))
        end
        assert_equal 0, source.pos
      end
      assert_equal "isolated original", File.binread(original)
    end
  end

  def test_equal_basenames_in_distinct_folders_are_preserved_without_flattening
    add("one/bolt.ipt", "first prototype")
    add("two/bolt.ipt", "second prototype")
    stage do |_|
      assert_equal "first prototype", File.binread(File.join(@staged_directory, "one/bolt.ipt"))
      assert_equal "second prototype", File.binread(File.join(@staged_directory, "two/bolt.ipt"))
      refute File.exist?(File.join(@staged_directory, "bolt.ipt"))
    end
  end

  def test_nested_primary_and_sibling_project_directories_keep_their_original_relationship
    @record.filename = "Assemblies/Main.iam"
    add("Parts/Part.ipt", "part outside assembly directory")
    stage do |input|
      assert_equal "part outside assembly directory",
        File.binread(File.join(File.dirname(input), "../Parts/Part.ipt"))
      refute File.exist?(File.join(File.dirname(input), "Part.ipt"))
    end
  end

  def test_case_colliding_directory_components_are_rejected_before_download
    add("Parts/one.ipt")
    conflicting = add("parts/two.ipt")
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) { stage { flunk "must not render" } }
    assert_includes error.message, "capitalization"
    assert_equal 0, conflicting.attachment.opens
  end

  def test_primary_row_returned_as_another_active_record_instance_is_not_downloaded_twice
    @model.model_files = [Record.new(@record.id, @record.filename, @record.attachment, @model)]
    stage { |input| assert_equal "current primary bytes", File.binread(input) }
    assert_equal 0, @record.attachment.opens
  end

  def test_absolute_traversal_and_ambiguous_component_paths_fail_before_reading_attachments
    ["/outside.ipt", "../outside.ipt", "part/../outside.ipt", "C:\\outside.ipt", "C:outside.ipt",
      "\\\\server\\share\\outside.ipt", "part//outside.ipt", "part/./outside.ipt", "bad\0.ipt"].each do |name|
      @model.model_files = [@record]
      record = add(name)
      assert_raises(ManyfoldThumbnails::AssemblyInputs::Error, name) { stage { flunk "must not render" } }
      assert_equal 0, record.attachment.opens
      assert_equal 0, @source.pos
    end
  end

  def test_invalid_primary_filename_is_refused_even_without_any_companions
    @record.filename = "../main.iam"
    assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) { stage { flunk "must not render" } }
  end

  def test_case_insensitive_duplicate_paths_and_file_directory_conflicts_are_rejected
    add("MAIN.iam")
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) { stage { flunk "must not render" } }
    assert_includes error.message, "duplicate"
    @model.model_files = [@record]
    add("Part.ipt")
    add("part.ipt/Child.ipt")
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) { stage { flunk "must not render" } }
    assert_includes error.message, "conflicting"
  end

  def test_document_limit_counts_primary_and_fails_before_opening_companions
    3.times { |index| add("part-#{index}.ipt") }
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) do
      stage(klass: limited_class(MAX_FILES: 3)) { flunk "must not render" }
    end
    assert_includes error.message, "document limit"
    assert @model.model_files.all? { it.attachment.opens.zero? }
  end

  def test_declared_aggregate_size_is_checked_before_any_companion_is_opened
    add("large.ipt", "large companion")
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) do
      stage(klass: limited_class(MAX_SOURCE_BYTES: 24)) { flunk "must not render" }
    end
    assert_includes error.message, "source limit"
    assert @model.model_files.all? { it.attachment.opens.zero? }
  end

  def test_streamed_aggregate_limit_handles_inaccurate_metadata_and_cleans_up
    @source = StringIO.new("1234")
    part = add("part.ipt", "56789", declared_size: 1)
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) do
      stage(klass: limited_class(MAX_SOURCE_BYTES: 8)) { flunk "must not render" }
    end
    assert_includes error.message, "source limit"
    assert_equal 1, part.attachment.closes
    assert_equal 0, @source.pos
  end

  def test_negative_metadata_cannot_reduce_the_preflight_aggregate
    add("large.ipt", "large companion", declared_size: 100)
    invalid = add("invalid.ipt", "negative metadata", declared_size: -100)
    error = assert_raises(ManyfoldThumbnails::AssemblyInputs::Error) do
      stage(klass: limited_class(MAX_SOURCE_BYTES: 24)) { flunk "must not render" }
    end
    assert_includes error.message, "negative declared"
    assert_equal 0, invalid.attachment.opens
    assert @model.model_files.all? { it.attachment.opens.zero? }
  end

  def test_deadline_applies_to_blocking_companion_download_and_closes_streams
    part = add("slow.ipt", "slow part", delay: 0.3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) { stage(seconds: 0.03) { flunk "must not render" } }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.25
    assert_equal 1, part.attachment.closes
    assert_equal 0, @source.pos
  end

  def test_expired_deadline_and_renderer_failure_remove_staged_files
    assert_raises(Timeout::Error) { stage(seconds: -1) { flunk "must not render" } }
    add("part.ipt")
    error = assert_raises(RuntimeError) { stage { raise "renderer failed" } }
    assert_equal "renderer failed", error.message
    assert_equal 0, @source.pos
  end

  def test_staging_requires_a_model_context_and_leaves_standalone_inputs_supported
    refute ManyfoldThumbnails::AssemblyInputs.applicable?(Struct.new(:filename).new("file.iam"))
    refute ManyfoldThumbnails::AssemblyInputs.applicable?(Record.new(1, "file.iam", nil, nil))
    assert ManyfoldThumbnails::AssemblyInputs.applicable?(@record)
  end
end
