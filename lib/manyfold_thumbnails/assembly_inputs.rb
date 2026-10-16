# frozen_string_literal: true

require "fileutils"
require "timeout"
require "tmpdir"

module ManyfoldThumbnails
  # Materialize named assembly attachments for Catwalk; parsing stays in Catwalk.
  class AssemblyInputs
    COMPANION_EXTENSIONS = {
      "iam" => %w[.ipt .iam].freeze,
      "sldasm" => %w[.sldprt .sldasm].freeze
    }.freeze
    MAX_FILES = 128
    MAX_SOURCE_BYTES = 256 * 1024 * 1024
    MAX_PATH_BYTES = 4096
    MAX_PATH_COMPONENTS = 64
    class Error < StandardError; end

    def self.assembly?(extension)
      COMPANION_EXTENSIONS.key?(extension)
    end

    def self.applicable?(record)
      record.respond_to?(:model) && record.model&.respond_to?(:model_files)
    end

    def initialize(file:, record:, deadline:)
      @file = file
      @record = record
      @deadline = deadline
      @project = "Assembly project"
    end

    def with_files
      Dir.mktmpdir("manyfold-catwalk-project-") do |directory|
        input = Timeout.timeout(remaining_time) { prepare(directory) }
        yield input
      end
    ensure
      @file.rewind if @file.respond_to?(:rewind)
    end

    private

    def remaining_time
      remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise Timeout::Error unless remaining.positive?

      remaining
    end

    def prepare(directory)
      primary_name = safe_filename(@record.filename)
      extension = File.extname(primary_name).delete_prefix(".").downcase
      @extensions = COMPANION_EXTENSIONS.fetch(extension)
      @project = (extension == "iam") ? "Inventor project" : "SolidWorks project"
      documents = [[primary_name, nil]]
      names = {primary_name.downcase => true}
      directories = {}
      check_directories!(primary_name, directories)
      native_records.each do |record|
        next if primary_record?(record)
        next unless @extensions.include?(File.extname(record.filename.to_s).downcase)

        attachment = record.attachment
        next unless attachment

        name = safe_filename(record.filename)
        raise Error, "#{@project} has duplicate component filenames: #{name}" if names[name.downcase]
        raise Error, "#{@project} exceeds the #{self.class::MAX_FILES}-document limit." if documents.length >= self.class::MAX_FILES

        check_directories!(name, directories)
        names[name.downcase] = true
        documents << [name, attachment]
      end
      # A component file cannot also be a directory containing another file.
      names.each_key do |name|
        parts = name.split("/")
        (1...parts.length).each do |length|
          if names[parts.first(length).join("/")]
            raise Error, "#{@project} has conflicting file and directory names."
          end
        end
      end
      declared_size = source_size(@file)
      documents.drop(1).each { |_, attachment| declared_size += source_size(attachment) }
      check_size!(declared_size)

      @bytes = 0
      documents.each do |name, attachment|
        destination = File.join(directory, name)
        FileUtils.mkdir_p(File.dirname(destination))
        File.open(destination, "wb") do |output|
          if attachment
            attachment.open { |source| copy(source, output) }
          else
            @file.rewind
            copy(@file, output)
          end
        end
      end
      File.join(directory, primary_name)
    rescue Error, Timeout::Error
      raise
    rescue StandardError => error
      raise Error, "Could not prepare #{@project} attachments: #{error.message}"
    end

    def native_records
      records = @record.model.model_files
      return records unless records.respond_to?(:where) && records.respond_to?(:limit)

      records.where("LOWER(filename) LIKE ? OR LOWER(filename) LIKE ?", *@extensions.map { |extension| "%#{extension}" })
        .where.not(attachment_data: nil).limit(self.class::MAX_FILES + 1)
    end

    def primary_record?(record)
      record.equal?(@record) ||
        (@record.respond_to?(:id) && @record.id && record.respond_to?(:id) && record.id == @record.id)
    end

    def check_directories!(name, directories)
      parts = name.split("/")
      (1...parts.length).each do |length|
        directory = parts.first(length).join("/")
        existing = directories[directory.downcase]
        if existing && existing != directory
          raise Error, "#{@project} has ambiguous directory capitalization."
        end
        directories[directory.downcase] = directory
      end
    end

    def safe_filename(filename)
      unless filename.is_a?(String) && filename.valid_encoding? &&
          filename.bytesize.positive? && filename.bytesize <= self.class::MAX_PATH_BYTES && !filename.include?("\0")
        raise Error, "#{@project} has an invalid component filename."
      end
      name = filename.tr("\\", "/")
      parts = name.split("/", -1)
      if name.start_with?("/") || parts.length > self.class::MAX_PATH_COMPONENTS ||
          parts.any? { |part| part.empty? || part == "." || part == ".." || part.include?(":") }
        raise Error, "#{@project} filenames must be relative paths without traversal."
      end

      name
    end

    def check_size!(size)
      if size > self.class::MAX_SOURCE_BYTES
        raise Error, "#{@project} exceeds the #{self.class::MAX_SOURCE_BYTES}-byte source limit."
      end
    end

    def source_size(source)
      size = source.size.to_i
      raise Error, "#{@project} has a negative declared source size." if size.negative?

      size
    end

    def copy(source, output)
      while (chunk = source.read([8192, self.class::MAX_SOURCE_BYTES + 1 - @bytes].min))
        remaining_time
        @bytes += chunk.bytesize
        check_size!(@bytes)
        output.write(chunk)
      end
    end
  end
end
