# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "tempfile"
require "timeout"
require_relative "executable"
require_relative "formats"

module ManyfoldThumbnails
  class Catwalk
    MAX_SOURCE_BYTES = 512 * 1024 * 1024
    MAX_OUTPUT_BYTES = 8 * 1024 * 1024
    MAX_ERROR_BYTES = 64 * 1024
    MAX_SECONDS = 60
    SIZE = 512
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
    class ProcessingError < StandardError; end

    attr_reader :status, :reason

    def self.binary
      Executable.path
    end

    def initialize(file:, record:)
      @file = file
      @record = record
    end

    def call
      @status = :missing_image
      @reason = "The file extension is not supported by Catwalk."
      extension = Formats.extension(@record)
      return {} unless Formats::CATWALK_EXTENSIONS.include?(extension)

      check_source_size!(@file.size)
      binary = self.class.binary
      deadline = monotonic_time + self.class::MAX_SECONDS
      output, diagnostic, exit_status = with_input(extension, deadline) { |path| run(binary, path, deadline) }
      unless exit_status == 0
        @status = (exit_status == 3) ? :missing_image : :failed
        @reason = diagnostic_reason(diagnostic, "Catwalk exited with status #{exit_status}.")
        warn_failure if @status == :failed
        return {}
      end
      unless output.start_with?(PNG_SIGNATURE) && output.byteslice(12, 4) == "IHDR" &&
          output.byteslice(16, 8)&.unpack("N2") == [SIZE, SIZE]
        raise ProcessingError, "Catwalk did not return a #{SIZE} x #{SIZE} PNG."
      end

      @status = :generated
      @reason = "Catwalk thumbnail generated."
      {render: StringIO.new(output)}
    rescue Timeout::Error
      fail_with("Catwalk exceeded the #{self.class::MAX_SECONDS}-second processing limit.")
    rescue ProcessingError, Executable::DownloadError, IOError, SystemCallError => error
      fail_with(error.message)
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining_time(deadline)
      remaining = deadline - monotonic_time
      raise Timeout::Error unless remaining.positive?

      remaining
    end

    def check_source_size!(size)
      raise ProcessingError, "The source is empty." unless size.to_i.positive?
      raise ProcessingError, "The source exceeds the #{self.class::MAX_SOURCE_BYTES}-byte processing limit." if size > self.class::MAX_SOURCE_BYTES
    end

    def with_input(extension, deadline)
      # Preserve the model directory for supported local sidecar resources.
      if @file.respond_to?(:path) && @file.path && File.file?(@file.path) &&
          File.extname(@file.path).downcase == ".#{extension}"
        check_source_size!(File.size(@file.path))
        return yield @file.path
      end

      # Shrine can supply downloaded files without their original extension.
      # Catwalk dispatches by extension, so restore it on a bounded local copy.
      Tempfile.create(["manyfold-catwalk-", ".#{extension}"], binmode: true) do |temporary|
        @file.rewind
        copied = 0
        Timeout.timeout(remaining_time(deadline)) do
          while (chunk = @file.read([8192, self.class::MAX_SOURCE_BYTES + 1 - copied].min))
            copied += chunk.bytesize
            check_source_size!(copied)
            temporary.write(chunk)
          end
        end
        temporary.flush
        check_source_size!(copied)
        yield temporary.path
      end
    ensure
      @file.rewind if @file.respond_to?(:rewind)
    end

    def run(binary, path, deadline)
      output = +"".b
      diagnostic = +"".b
      Open3.popen3(binary, path, "--output", "-", "--size", SIZE.to_s,
        "--transparent", pgroup: true) do |input, stdout, stderr, process|
        completed = false
        input.close
        streams = {stdout => [output, self.class::MAX_OUTPUT_BYTES], stderr => [diagnostic, self.class::MAX_ERROR_BYTES]}
        until streams.empty?
          ready = IO.select(streams.keys, nil, nil, remaining_time(deadline))
          raise Timeout::Error unless ready

          ready.first.each do |stream|
            chunk = stream.read_nonblock(8192, exception: false)
            case chunk
            when :wait_readable
              next
            when nil
              streams.delete(stream)
            else
              bytes, limit = streams.fetch(stream)
              raise ProcessingError, "Catwalk exceeded the #{limit}-byte output limit." if bytes.bytesize + chunk.bytesize > limit

              bytes << chunk
            end
          end
        end
        raise Timeout::Error unless process.join(remaining_time(deadline))

        completed = true
        [output, diagnostic, process.value.exitstatus]
      ensure
        # Kill the process group before Open3 waits, including any descendants
        # still holding its pipes. Timeout and output-limit failures stay bounded.
        unless completed
          begin
            Process.kill("KILL", -process.pid)
          rescue Errno::ESRCH
            nil
          end
        end
        process.join
      end
    end

    def diagnostic_reason(diagnostic, fallback)
      text = diagnostic.force_encoding(Encoding::UTF_8).scrub.strip
      text.empty? ? fallback : text[0, 1000]
    end

    def fail_with(message)
      @status = :failed
      @reason = message
      warn_failure
      {}
    end

    def warn_failure
      Rails.logger.warn("Catwalk thumbnail generation: #{@reason}") if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
    end
  end
end
