# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "openssl"
require "rbconfig"
require "timeout"
require "tmpdir"
require "uri"

module ManyfoldThumbnails
  # Install the pinned upstream executable on first use. This is deliberately
  # separate from Rails initialization and the thumbnail processing deadline.
  class Executable
    MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
    MAX_EXTRACTED_BYTES = 128 * 1024 * 1024
    MAX_SECONDS = 120
    MAX_REDIRECTS = 5
    DOWNLOAD_HOSTS = %w[github.com release-assets.githubusercontent.com objects.githubusercontent.com].freeze
    MANIFEST_PATH = File.expand_path("../../config/catwalk.json", __dir__)
    class DownloadError < StandardError; end

    def self.path
      new.path
    end

    def initialize(manifest_path: MANIFEST_PATH, cache_root: nil,
      platform: RbConfig::CONFIG.fetch("host_os"), cpu: RbConfig::CONFIG.fetch("host_cpu"))
      @manifest_path = manifest_path
      @cache_root = cache_root
      @platform = platform
      @cpu = cpu
    end

    def path
      configured = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
      return configured unless configured.nil? || configured.empty?

      target = target_for_platform
      metadata = manifest
      version = metadata.fetch("version")
      release = metadata.fetch("targets").fetch(target) do
        raise DownloadError, "The pinned Catwalk release has no executable for #{target}."
      end
      validate_release!(version, release)
      version_directory = File.join(cache_root, version)
      destination = File.join(version_directory, target)

      Timeout.timeout(self.class::MAX_SECONDS, DownloadError,
        "Catwalk download exceeded the #{self.class::MAX_SECONDS}-second limit.") do
        deadline = monotonic_time + self.class::MAX_SECONDS
        FileUtils.mkdir_p(version_directory)
        with_lock(File.join(version_directory, ".#{target}.lock"), deadline) do
          unless verified_installation?(destination, target, release, version)
            install(destination, target, release, version, deadline)
          end
        end
      end
      File.join(destination, "catwalk")
    rescue DownloadError
      raise
    rescue JSON::ParserError, KeyError, IOError, SystemCallError, Timeout::Error,
      Net::HTTPError, Net::ProtocolError, OpenSSL::SSL::SSLError, SocketError => error
      raise DownloadError, "Catwalk download failed: #{error.message}"
    end

    protected

    # Keep transport separate so installation can be tested without networking.
    def request(uri, deadline, &block)
      timeout = remaining_time(deadline)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        verify_mode: OpenSSL::SSL::VERIFY_PEER,
        open_timeout: [timeout, 10].min, read_timeout: [timeout, 30].min,
        write_timeout: [timeout, 10].min, max_retries: 0) do |http|
        request = Net::HTTP::Get.new(uri.request_uri,
          "User-Agent" => "manyfold-thumbnails", "Accept" => "application/octet-stream",
          "Accept-Encoding" => "identity")
        http.request(request, &block)
      end
    end

    private

    def cache_root
      return File.expand_path(@cache_root) if @cache_root

      configured = ENV["MANYFOLD_THUMBNAILS_CATWALK_CACHE"]
      return File.expand_path(configured) unless configured.nil? || configured.empty?

      plugin_directory = if defined?(PluginManager) && PluginManager.respond_to?(:path)
        PluginManager.path
      elsif ENV["PLUGINS_PATH"] && !ENV["PLUGINS_PATH"].empty?
        ENV.fetch("PLUGINS_PATH")
      elsif defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("plugins")
      else
        raise DownloadError, "Set MANYFOLD_THUMBNAILS_CATWALK_CACHE to a writable persistent directory."
      end
      File.expand_path(File.join(plugin_directory, ".cache", "manyfold_thumbnails"))
    end

    def target_for_platform
      unless @platform.match?(/linux/i)
        raise DownloadError, "Catwalk downloads support Linux only; set MANYFOLD_THUMBNAILS_CATWALK."
      end

      architecture = case @cpu
      when /\A(?:x86_64|amd64)\z/ then "x86_64"
      when /\A(?:aarch64|arm64)\z/ then "aarch64"
      else
        raise DownloadError, "No Catwalk executable for this architecture; set MANYFOLD_THUMBNAILS_CATWALK."
      end
      "#{architecture}-unknown-linux-musl"
    end

    def manifest
      metadata = JSON.parse(File.read(@manifest_path))
      unless metadata.is_a?(Hash) && metadata["targets"].is_a?(Hash)
        raise DownloadError, "Invalid pinned Catwalk release manifest."
      end
      metadata
    end

    def validate_release!(version, release)
      unless version.is_a?(String) && version.match?(/\A\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?\z/) &&
          release.is_a?(Hash) && release["files"].is_a?(Hash) &&
          %w[catwalk LICENSE release.json].all? { |name| release["files"].key?(name) } &&
          valid_checksum?(release["sha256"]) &&
          release["files"].all? { |name, checksum| name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]+\z/) && name != "." && name != ".." && valid_checksum?(checksum) }
        raise DownloadError, "Invalid pinned Catwalk release manifest."
      end
      validated_uri(release.fetch("url"))
    end

    def valid_checksum?(checksum)
      checksum.is_a?(String) && checksum.match?(/\A[0-9a-f]{64}\z/)
    end

    def validated_uri(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.fragment.nil? &&
          self.class::DOWNLOAD_HOSTS.include?(uri.host)
        raise DownloadError, "Catwalk downloads require an HTTPS GitHub release URL."
      end
      uri
    rescue URI::InvalidURIError, TypeError
      raise DownloadError, "Invalid Catwalk release URL."
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def remaining_time(deadline)
      remaining = deadline - monotonic_time
      raise DownloadError, "Catwalk download exceeded the #{self.class::MAX_SECONDS}-second limit." unless remaining.positive?

      remaining
    end

    def with_lock(path, deadline)
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(path, flags, 0o600) do |lock|
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          sleep [remaining_time(deadline), 0.05].min
        end
        remaining_time(deadline)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def verified_installation?(directory, target, release, version)
      return false unless File.directory?(directory) && !File.symlink?(directory)
      total_bytes = 0
      return false unless release.fetch("files").all? do |name, checksum|
        path = File.join(directory, name)
        next false unless File.file?(path) && !File.symlink?(path)

        total_bytes += File.size(path)
        total_bytes <= self.class::MAX_EXTRACTED_BYTES && Digest::SHA256.file(path).hexdigest == checksum
      end

      metadata = JSON.parse(File.read(File.join(directory, "release.json")))
      return false unless metadata["version"] == version && metadata["target"] == target && metadata["binary"] == "catwalk"

      binary = File.join(directory, "catwalk")
      return false if (File.stat(binary).mode & 0o111).zero?
      unless File.executable?(binary)
        raise DownloadError, "The Catwalk cache does not permit execution. Set MANYFOLD_THUMBNAILS_CATWALK_CACHE " \
          "to a writable directory on a filesystem that permits execution."
      end
      true
    rescue JSON::ParserError, IOError, SystemCallError
      false
    end

    def install(destination, target, release, version, deadline)
      Dir.mktmpdir(".catwalk-", File.dirname(destination)) do |temporary|
        archive_path = File.join(temporary, "release.zip")
        checksum = download(release.fetch("url"), archive_path, deadline)
        unless checksum == release.fetch("sha256")
          raise DownloadError, "Catwalk archive checksum mismatch."
        end

        extracted = File.join(temporary, "extracted")
        FileUtils.mkdir(extracted)
        extract(archive_path, extracted, target, release, version, deadline)
        unless verified_installation?(extracted, target, release, version)
          raise DownloadError, "Catwalk release files or metadata failed verification."
        end

        remaining_time(deadline)
        FileUtils.rm_rf(destination)
        File.rename(extracted, destination)
      end
    end

    def download(url, destination, deadline)
      uri = validated_uri(url)
      redirects = 0
      loop do
        redirect = nil
        checksum = nil
        request(uri, deadline) do |response|
          remaining_time(deadline)
          case response.code.to_i
          when 200
            checksum = save_response(response, destination, deadline)
          when 301, 302, 303, 307, 308
            redirects += 1
            raise DownloadError, "Catwalk download exceeded the redirect limit." if redirects > self.class::MAX_REDIRECTS
            raise DownloadError, "Catwalk download redirect has no destination." unless response["location"]

            redirect = validated_uri(URI.join(uri.to_s, response["location"]).to_s)
          else
            raise DownloadError, "Catwalk download returned HTTP #{response.code}."
          end
        end
        return checksum unless redirect

        uri = redirect
      end
    rescue URI::InvalidURIError
      raise DownloadError, "Invalid Catwalk download redirect."
    end

    def save_response(response, destination, deadline)
      content_length = response["content-length"] && Integer(response["content-length"], 10)
      if content_length && (content_length.negative? || content_length > self.class::MAX_DOWNLOAD_BYTES)
        raise DownloadError, "Catwalk archive exceeds the #{self.class::MAX_DOWNLOAD_BYTES}-byte download limit."
      end
      checksum = Digest::SHA256.new
      bytes = 0
      File.open(destination, "wb", 0o600) do |file|
        response.read_body do |chunk|
          remaining_time(deadline)
          bytes += chunk.bytesize
          raise DownloadError, "Catwalk archive exceeds the #{self.class::MAX_DOWNLOAD_BYTES}-byte download limit." if bytes > self.class::MAX_DOWNLOAD_BYTES

          file.write(chunk)
          checksum.update(chunk)
        end
      end
      if content_length && bytes != content_length
        raise DownloadError, "Catwalk archive download was incomplete."
      end
      checksum.hexdigest
    rescue ArgumentError
      raise DownloadError, "Invalid Catwalk archive content length."
    end

    def extract(archive_path, destination, target, release, version, deadline)
      require "ffi-libarchive"
      expected = release.fetch("files").keys.to_h do |name|
        ["catwalk3d-#{version}-#{target}/#{name}", name]
      end
      seen = []
      total_bytes = 0
      Archive::Reader.open_filename(archive_path) do |reader|
        reader.each_entry do |entry|
          remaining_time(deadline)
          name = expected[entry.pathname]
          unless name && !seen.include?(name) && entry.file? && !entry.symbolic_link? && entry.hardlink.nil?
            raise DownloadError, "Unexpected file in Catwalk release archive."
          end
          if entry.size.negative? || entry.size > self.class::MAX_EXTRACTED_BYTES - total_bytes
            raise DownloadError, "Catwalk release exceeds the #{self.class::MAX_EXTRACTED_BYTES}-byte extraction limit."
          end

          checksum = Digest::SHA256.new
          bytes = 0
          path = File.join(destination, name)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            reader.read_data(16_384) do |chunk|
              remaining_time(deadline)
              bytes += chunk.bytesize
              total_bytes += chunk.bytesize
              raise DownloadError, "Catwalk release exceeds the #{self.class::MAX_EXTRACTED_BYTES}-byte extraction limit." if total_bytes > self.class::MAX_EXTRACTED_BYTES

              file.write(chunk)
              checksum.update(chunk)
            end
          end
          unless bytes == entry.size && checksum.hexdigest == release.fetch("files").fetch(name)
            raise DownloadError, "Catwalk release file checksum mismatch: #{name}."
          end

          File.chmod(name == "catwalk" ? 0o755 : 0o644, path)
          seen << name
        end
      end
      raise DownloadError, "Catwalk release archive is missing required files." unless seen.sort == expected.values.sort
    rescue LoadError
      raise DownloadError, "Catwalk download requires Manyfold's ffi-libarchive dependency."
    rescue Archive::Error => error
      raise DownloadError, "Invalid Catwalk release archive: #{error.message}"
    end
  end
end
