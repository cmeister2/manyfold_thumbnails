# frozen_string_literal: true

require "open3"
require "timeout"

helper = File.expand_path("worker_startup.rb", __dir__)
ready = false
Open3.popen2e("bundle", "exec", "sidekiq", "--require", helper,
  "--queue", "thumbnail-startup-check", "--concurrency", "1", "--timeout", "1") do |input, output, process|
  input.close
  begin
    Timeout.timeout(45) do
      output.each_line do |line|
        $stdout.write(line)
        next unless line.include?("THUMBNAIL_WORKER_READY")

        ready = true
        break
      end
    end
    raise "Sidekiq exited before confirming thumbnail startup" unless ready
  ensure
    Process.kill("TERM", process.pid) if process.alive?
    begin
      status = Timeout.timeout(10) { process.value }
    rescue Timeout::Error
      Process.kill("KILL", process.pid) if process.alive?
      process.value
      raise "Sidekiq did not shut down after the startup check"
    end
  end
  raise "Sidekiq startup check failed with #{status}" unless status.success?
end
