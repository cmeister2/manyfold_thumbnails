# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "support/catwalk_release_fixture"
require_relative "support/temporary_method"
require_relative "../lib/manyfold_thumbnails/executable"
require_relative "../lib/manyfold_thumbnails/catwalk"

class CatwalkExecutableTest < Minitest::Test
  include TemporaryMethod

  class FixtureExecutable < ManyfoldThumbnails::Executable
    attr_reader :requests
    attr_accessor :responses, :request_log, :request_delay

    def initialize(**options)
      super
      @requests = []
      @responses = []
    end

    private

    def request(uri, deadline)
      @requests << uri
      File.open(request_log, "a") { |log| log.puts(uri) } if request_log
      sleep request_delay if request_delay
      response = responses.shift
      raise response if response.is_a?(Exception)
      raise "Unexpected download: #{uri}" unless response

      yield response
    end
  end

  def setup
    @directory = Dir.mktmpdir("manyfold-catwalk-executable-test-")
    @cache = File.join(@directory, "cache")
    @manifest_path = File.join(@directory, "catwalk.json")
    @archive = CatwalkReleaseFixture.archive
    write_manifest
    @original_binary = ENV["MANYFOLD_THUMBNAILS_CATWALK"]
    @original_cache = ENV["MANYFOLD_THUMBNAILS_CATWALK_CACHE"]
    ENV.delete("MANYFOLD_THUMBNAILS_CATWALK")
  end

  def teardown
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = @original_binary
    ENV["MANYFOLD_THUMBNAILS_CATWALK_CACHE"] = @original_cache
    FileUtils.remove_entry(@directory)
  end

  def write_manifest(archive: @archive, files: CatwalkReleaseFixture.files)
    File.write(@manifest_path, JSON.generate(CatwalkReleaseFixture.manifest(archive: archive, files: files)))
  end

  def downloader(klass: FixtureExecutable, **options)
    klass.new(manifest_path: @manifest_path, cache_root: @cache,
      platform: "linux-gnu", cpu: "x86_64", **options).tap do |instance|
      instance.responses = [response(body: @archive)]
    end
  end

  def response(body: "", code: "200", headers: {}, chunks: nil)
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
    klass.new("1.1", code, "Test response").tap do |result|
      headers.each { |name, value| result[name] = value.to_s }
      result.define_singleton_method(:read_body) do |&block|
        (chunks || [body]).each(&block)
      end
    end
  end

  def destination
    File.join(@cache, CatwalkReleaseFixture::VERSION, CatwalkReleaseFixture::TARGET)
  end

  def assert_no_installed_release
    refute File.exist?(File.join(destination, "catwalk"))
    refute Dir.glob(File.join(@cache, "**", ".catwalk-*"), File::FNM_DOTMATCH).any?,
      "Failed installs must remove temporary download and extraction files"
  end

  def test_first_use_downloads_verifies_and_caches_the_complete_release
    executable = downloader
    refute File.exist?(@cache), "Constructing a downloader must not create a cache or fetch files"
    assert_empty executable.requests

    binary = executable.path
    assert_equal File.join(destination, "catwalk"), binary
    assert File.executable?(binary)
    CatwalkReleaseFixture.files.each do |name, bytes|
      assert_equal bytes, File.binread(File.join(destination, name))
    end
    assert_equal [CatwalkReleaseFixture::URL], executable.requests.map(&:to_s)

    cached = downloader
    cached.responses.clear
    assert_equal binary, cached.path
    assert_empty cached.requests, "A second worker must reuse the verified cache without downloading"
  end

  def test_binary_release_bytes_are_preserved_with_utf8_default_encodings
    original_external = Encoding.default_external
    original_internal = Encoding.default_internal
    binary_bytes = "\x7FELF\x00\x80\xFF".b
    files = CatwalkReleaseFixture.files.merge("catwalk" => binary_bytes)
    @archive = CatwalkReleaseFixture.archive(files)
    write_manifest(archive: @archive, files: files)
    Encoding.default_external = Encoding::UTF_8
    Encoding.default_internal = Encoding::UTF_8

    executable = downloader
    binary = executable.path
    assert File.executable?(binary)
    assert_equal binary_bytes, File.binread(binary)
    assert_equal [CatwalkReleaseFixture::URL], executable.requests.map(&:to_s)

    cached = downloader
    cached.responses.clear
    assert_equal binary, cached.path
    assert_equal binary_bytes, File.binread(binary)
    assert_empty cached.requests, "Binary bytes must remain valid when a worker verifies the cached release"
  ensure
    Encoding.default_external = original_external
    Encoding.default_internal = original_internal
  end

  def test_changed_cached_binary_is_replaced_by_a_verified_download
    original = downloader.path
    File.binwrite(original, "tampered")
    executable = downloader
    assert_equal original, executable.path
    assert_equal CatwalkReleaseFixture.files.fetch("catwalk"), File.binread(original)
    assert_equal 1, executable.requests.size
  end

  def test_archive_checksum_mismatch_and_truncated_download_are_rejected
    [@archive.sub("Authored", "Altered"), @archive.byteslice(0, @archive.bytesize / 2)].each do |bytes|
      executable = downloader
      executable.responses = [response(body: bytes)]
      error = assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_match(/checksum|download|archive/i, error.message)
      assert_no_installed_release
    end
  end

  def test_verified_archive_with_wrong_member_checksum_is_rejected
    files = CatwalkReleaseFixture.files.merge("catwalk" => "unexpected executable")
    @archive = CatwalkReleaseFixture.archive(files)
    # The archive itself is pinned correctly; the per-file hash still describes
    # the intended executable, so extraction must reject the replacement.
    write_manifest(archive: @archive)
    executable = downloader
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
    assert_no_installed_release
  end

  def test_verified_archive_with_unexpected_path_is_rejected
    files = CatwalkReleaseFixture.files.merge("../../outside" => "unexpected")
    @archive = CatwalkReleaseFixture.archive(files)
    write_manifest(archive: @archive)
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { downloader.path }
    assert_no_installed_release
    refute File.exist?(File.join(@directory, "outside"))
  end

  def test_missing_member_and_mismatched_release_metadata_are_rejected
    @archive = CatwalkReleaseFixture.archive(CatwalkReleaseFixture.files.reject { |name, _| name == "LICENSE" })
    write_manifest(archive: @archive)
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { downloader.path }
    assert_no_installed_release

    files = CatwalkReleaseFixture.files.merge("release.json" =>
      JSON.generate(version: "9.9.9", target: CatwalkReleaseFixture::TARGET, binary: "catwalk"))
    @archive = CatwalkReleaseFixture.archive(files)
    write_manifest(archive: @archive, files: files)
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { downloader.path }
    assert_no_installed_release
  end

  def test_declared_and_streamed_download_size_limits_are_enforced
    klass = Class.new(FixtureExecutable)
    klass.const_set(:MAX_DOWNLOAD_BYTES, 32)
    [response(body: "tiny", headers: {"content-length" => 33}),
      response(chunks: ["a" * 20, "b" * 20])].each do |reply|
      executable = downloader(klass: klass)
      executable.responses = [reply]
      assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_no_installed_release
    end
  end

  def test_extracted_size_limit_is_enforced_before_installation
    klass = Class.new(FixtureExecutable)
    klass.const_set(:MAX_EXTRACTED_BYTES, 8)
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { downloader(klass: klass).path }
    assert_no_installed_release
  end

  def test_https_redirect_fetches_the_release_asset
    executable = downloader
    target = "https://release-assets.githubusercontent.com/test/release.zip"
    executable.responses = [response(code: "302", headers: {"location" => target}), response(body: @archive)]
    assert File.executable?(executable.path)
    assert_equal [CatwalkReleaseFixture::URL, target], executable.requests.map(&:to_s)
  end

  def test_insecure_and_excessive_redirects_are_rejected
    executable = downloader
    executable.responses = [response(code: "302", headers: {"location" => "http://example.invalid/catwalk.zip"})]
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
    assert_equal 1, executable.requests.size
    assert_no_installed_release

    klass = Class.new(FixtureExecutable)
    klass.const_set(:MAX_REDIRECTS, 1)
    executable = downloader(klass: klass)
    executable.responses = Array.new(3) { response(code: "302", headers: {"location" => CatwalkReleaseFixture::URL}) }
    assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
    assert_operator executable.requests.size, :<=, 2
    assert_no_installed_release
  end

  def test_http_error_and_timeout_leave_no_executable_and_allow_retry
    [response(code: "404"), Net::ReadTimeout.new("fixture read timed out")].each do |reply|
      executable = downloader
      executable.responses = [reply]
      assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_no_installed_release
    end
    assert File.executable?(downloader.path)
  end

  def test_http_transport_uses_verified_tls_and_bounded_timeouts
    request = nil
    arguments = nil
    options = nil
    reply = response(body: @archive)
    http = Object.new
    http.define_singleton_method(:request) do |value, &block|
      request = value
      block.call(reply)
    end
    transport = lambda do |*values, **settings, &block|
      arguments = values
      options = settings
      block.call(http)
    end
    executable = ManyfoldThumbnails::Executable.new(manifest_path: @manifest_path,
      cache_root: @cache, platform: "linux", cpu: "x86_64")
    with_temporary_method(Net::HTTP, :start, transport) { assert File.executable?(executable.path) }
    assert_equal ["github.com", 443], arguments
    assert options.fetch(:use_ssl)
    assert_equal OpenSSL::SSL::VERIFY_PEER, options.fetch(:verify_mode)
    assert_operator options.fetch(:open_timeout), :<=, 10
    assert_operator options.fetch(:read_timeout), :<=, 30
    assert_operator options.fetch(:write_timeout), :<=, 10
    assert_equal 0, options.fetch(:max_retries)
    assert_equal "identity", request["Accept-Encoding"]
  end

  def test_supported_cpu_aliases_and_unsupported_platforms
    assert File.executable?(downloader(cpu: "amd64").path)
    [["darwin", "x86_64"], ["linux", "riscv64"]].each do |platform, cpu|
      executable = downloader(platform: platform, cpu: cpu)
      error = assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_match(/MANYFOLD_THUMBNAILS_CATWALK|unsupported|Linux|architecture/i, error.message)
      assert_empty executable.requests
    end
  end

  def test_explicit_binary_override_does_not_download_or_create_a_cache
    configured = File.join(@directory, "user supplied catwalk")
    ENV["MANYFOLD_THUMBNAILS_CATWALK"] = configured
    ENV["MANYFOLD_THUMBNAILS_CATWALK_CACHE"] = @cache
    assert_equal configured, ManyfoldThumbnails::Executable.path
    assert_equal configured, ManyfoldThumbnails::Catwalk.binary
    refute File.exist?(@cache)
  end

  def test_cache_environment_selects_a_writable_persistent_directory
    ENV["MANYFOLD_THUMBNAILS_CATWALK_CACHE"] = @cache
    executable = FixtureExecutable.new(manifest_path: @manifest_path, platform: "linux", cpu: "x86_64")
    executable.responses = [response(body: @archive)]
    assert_equal File.join(destination, "catwalk"), executable.path
  end

  def test_unwritable_cache_is_an_actionable_download_failure
    executable = downloader(cache_root: "/proc/manyfold-thumbnails-test-#{Process.pid}")
    error = assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
    assert_match(/cache|write|directory|MANYFOLD_THUMBNAILS_CATWALK/i, error.message)
    assert_empty executable.requests
  end

  def test_cached_release_on_a_filesystem_that_blocks_execution_is_not_downloaded_again
    binary = downloader.path
    assert_equal 0o755, File.stat(binary).mode & 0o777
    executable = downloader
    executable.responses.clear
    original = File.method(:executable?)
    blocked = lambda { |path| path == binary ? false : original.call(path) }
    with_temporary_method(File, :executable?, blocked) do
      error = assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_includes error.message, "MANYFOLD_THUMBNAILS_CATWALK_CACHE"
      assert_match(/filesystem.*execution|permit execution/, error.message)
    end
    assert_empty executable.requests, "A noexec cache must report the problem without repeating the same download"
    assert_equal CatwalkReleaseFixture.files.fetch("catwalk"), File.binread(binary)
  end

  def test_two_processes_share_one_download_through_the_cache_lock
    log = File.join(@directory, "requests")
    children = 2.times.map do
      fork do
        executable = downloader
        executable.request_log = log
        executable.request_delay = 0.15
        begin
          executable.path
          exit! 0
        rescue StandardError => error
          warn error.full_message
          exit! 1
        end
      end
    end
    children.each do |pid|
      _, status = Process.wait2(pid)
      assert status.success?, "Both workers should acquire the same verified executable"
    end
    assert_equal [CatwalkReleaseFixture::URL], File.readlines(log, chomp: true)
    assert File.executable?(File.join(destination, "catwalk"))
  end

  def test_waiting_for_another_worker_obeys_the_download_deadline
    klass = Class.new(FixtureExecutable)
    klass.const_set(:MAX_SECONDS, 0.1)
    FileUtils.mkdir_p(File.dirname(destination))
    lock_path = File.join(File.dirname(destination), ".#{CatwalkReleaseFixture::TARGET}.lock")
    File.open(lock_path, "w") do |lock|
      lock.flock(File::LOCK_EX)
      executable = downloader(klass: klass)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(ManyfoldThumbnails::Executable::DownloadError) { executable.path }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
      assert_empty executable.requests
    end
    assert_no_installed_release
  end

  def test_requiring_thumbnail_classes_does_not_download_during_boot
    source = <<~RUBY
      require "net/http"
      class << Net::HTTP
        def start(*)
          abort "Application boot must not download Catwalk"
        end
      end
      require "manyfold_thumbnails/catwalk"
      abort "Application boot created the download cache" if File.exist?(ENV.fetch("MANYFOLD_THUMBNAILS_CATWALK_CACHE"))
    RUBY
    library = File.expand_path("../lib", __dir__)
    output, status = Open3.capture2e({"MANYFOLD_THUMBNAILS_CATWALK_CACHE" => @cache},
      RbConfig.ruby, "-I", library, "-e", source)
    assert status.success?, output
  end
end
