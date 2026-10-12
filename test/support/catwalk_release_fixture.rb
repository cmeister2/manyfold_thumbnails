# frozen_string_literal: true

require "digest"
require "json"
require "zlib"

# A tiny authored release archive exercises verification without fetching or
# executing third-party code. Stored ZIP entries keep the fixture dependency free.
module CatwalkReleaseFixture
  VERSION = "2.0.0"
  TARGET = "x86_64-unknown-linux-musl"
  URL = "https://github.com/example/catwalk/releases/download/#{VERSION}/catwalk.zip"

  def self.files
    {
      "catwalk" => "#!/bin/sh\nexit 0\n",
      "LICENSE" => "Authored test fixture.\n",
      "release.json" => JSON.generate(version: VERSION, target: TARGET, binary: "catwalk")
    }
  end

  def self.archive(files = self.files, prefix: "catwalk3d-#{VERSION}-#{TARGET}/")
    local = +"".b
    central = +"".b
    files.each do |basename, content|
      name = "#{prefix}#{basename}".b
      content = content.b
      checksum = Zlib.crc32(content)
      offset = local.bytesize
      local << [0x04034b50, 20, 0, 0, 0, 0, checksum, content.bytesize,
        content.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") << name << content
      central << [0x02014b50, 20, 20, 0, 0, 0, 0, checksum, content.bytesize,
        content.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
    end
    local + central + [0x06054b50, 0, 0, files.size, files.size,
      central.bytesize, local.bytesize, 0].pack("VvvvvVVv")
  end

  def self.manifest(archive: self.archive, files: self.files)
    {
      "version" => VERSION,
      "repository" => "https://github.com/example/catwalk",
      "targets" => {
        TARGET => {
          "url" => URL,
          "sha256" => Digest::SHA256.hexdigest(archive),
          "files" => files.transform_values { |content| Digest::SHA256.hexdigest(content) }
        }
      }
    }
  end
end
