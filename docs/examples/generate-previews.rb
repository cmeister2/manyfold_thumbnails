#!/usr/bin/env ruby
# frozen_string_literal: true

# Rebuild authored saved-preview carriers and their 512px extracted thumbnails.
# The .ipt/.iam/.f3d files contain saved images, not Autodesk CAD geometry.
# Their image sources are separate OBJ files; no raster compositing is used.
#
# CATWALK_BINARY=/path/to/pinned/catwalk ruby docs/examples/generate-previews.rb
# Requires the checksum-pinned Linux Catwalk 2.0.0 release and Ruby's stdlib.

require "digest"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "zlib"
require_relative "../../test/support/inventor_fixture"

module ExamplePreviews
  GEAR_SHA256 = "4e69c36fb92dc077d82097bd300093f8dd1be8f83380dae04657f3ba80c6ff1f"
  # Original procedural gear from Catwalk commit ddfa03730888e933142f47ad56405ac72903854a.
  # The upstream MIT notice is retained in docs/examples/LICENSE-catwalk.txt.

  module_function

  def command(binary, *arguments)
    output, error, status = Open3.capture3(binary.to_s, *arguments.map(&:to_s), binmode: true)
    abort "Catwalk failed (#{status.exitstatus}): #{error}" unless status.success?
    output
  end

  def dimensions(png)
    abort "Not a PNG image" unless png.start_with?("\x89PNG\r\n\x1a\n".b) && png.byteslice(12, 4) == "IHDR"
    png.byteslice(16, 8).unpack("NN")
  end

  def two_gears(original)
    lines = original.lines
    vertices = lines.count { it.start_with?("v ") }
    abort "Unexpected upstream gear OBJ records" unless lines.all? { it.strip.empty? || it.start_with?("#", "v ", "f ") }
    result = +"# Two translated copies of Catwalk's MIT procedural gear.\n"
    [0.0, 2.4].each_with_index do |translation, copy|
      result << "o gear_#{copy + 1}\n"
      lines.each do |line|
        words = line.split
        case words.first
        when "v"
          abort "Unexpected upstream gear vertex" unless words.length == 4
          x, y, z = words.drop(1).map { Float(it) }
          result << format("v %.9f %.9f %.9f\n", x + translation, y, z)
        when "f"
          indices = words.drop(1).map do |word|
            index = Integer(word)
            abort "Invalid upstream gear face index" unless index.between?(1, vertices)
            index + copy * vertices
          end
          result << "f #{indices.join(' ')}\n"
        end
      end
    end
    result
  end

  def triangle
    # A thin triangular prism with independent vertices for flat face colors.
    # This is presentation geometry, not a Fusion-exported design.
    corners = [[-1, -0.12, 0], [1, -0.12, 0], [0, -0.12, 2.8],
               [-1, 0.12, 0], [1, 0.12, 0], [0, 0.12, 2.8]]
    faces = [
      [[0, 1, 2], [0.34, 0.68, 0.82]],
      [[5, 4, 3], [0.28, 0.58, 0.73]],
      [[1, 4, 5, 2], [0.37, 0.66, 0.36]],
      [[3, 0, 2, 5], [0.30, 0.62, 0.75]],
      [[3, 4, 1, 0], [0.24, 0.49, 0.63]]
    ]
    result = +"# Authored colored triangular prism; no companion materials needed.\n"
    index = 0
    faces.each do |face, color|
      indices = face.map do |corner|
        result << "v #{(corners.fetch(corner) + color).join(' ')}\n"
        index += 1
      end
      result << "f #{indices.join(' ')}\n"
    end
    result
  end

  def fusion(png)
    manifest = ["3-2-0-0", "FusionDocType"].map { [it.bytesize].pack("V") + it.b }.join.b
    manifest << [4].pack("V") << ".f3d".encode("UTF-16LE").b
    active = [15].pack("V") + "FusionAssetName".encode("UTF-16LE").b
    assets = {"Manifest.dat" => manifest, "FusionAssetName[Active]/Manifest.dat" => active,
              "FusionAssetName[Active]/Previews/small.png" => png}
    # Deterministic, single-disk ZIP32 with the qualified active-design carrier.
    # The manifest layout matches Catwalk's authored Fusion protocol fixtures.
    output = "".b
    directory = "".b
    assets.each do |name, bytes|
      name = name.b
      compressor = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      compressed = compressor.deflate(bytes, Zlib::FINISH)
      compressor.close
      crc = Zlib.crc32(bytes)
      offset = output.bytesize
      output << [0x04034b50, 20, 0, 8, 0, 33, crc, compressed.bytesize, bytes.bytesize,
                 name.bytesize, 0].pack("VvvvvvVVVvv") << name << compressed
      directory << [0x02014b50, 20, 20, 0, 8, 0, 33, crc, compressed.bytesize, bytes.bytesize,
                    name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") << name
    end
    offset = output.bytesize
    output << directory
    output << [0x06054b50, 0, 0, assets.length, assets.length, directory.bytesize, offset, 0].pack("VvvvvVVv")
    output
  end

  def main
    examples = Pathname.new(__dir__)
    root = examples.parent.parent
    inputs = examples.join("inputs")
    metadata = JSON.parse(root.join("config/catwalk.json").read)
    architecture = case RbConfig::CONFIG.fetch("host_cpu")
    when /\A(?:x86_64|amd64)\z/ then "x86_64"
    when /\A(?:aarch64|arm64)\z/ then "aarch64"
    else abort "Use the pinned Linux x86_64 or aarch64 Catwalk release."
    end
    binary = Pathname.new(ENV.fetch("CATWALK_BINARY", root.join("test/vendor/catwalk/#{architecture}-unknown-linux-musl/catwalk").to_s))
    abort "Missing Catwalk executable; set CATWALK_BINARY to the pinned Linux release." unless binary.file? && binary.executable?
    expected = metadata.fetch("targets").fetch("#{architecture}-unknown-linux-musl").fetch("files").fetch("catwalk")
    abort "Catwalk checksum does not match the pinned release." unless Digest::SHA256.file(binary).hexdigest == expected
    abort "Unexpected Catwalk version." unless command(binary, "--version").strip == "catwalk 2.0.0"
    gear = inputs.join("gear.obj")
    abort "Gear OBJ differs from the pinned upstream source." unless Digest::SHA256.file(gear).hexdigest == GEAR_SHA256
    inputs.join("gears.obj").write(two_gears(gear.read))
    inputs.join("triangle.obj").write(triangle)

    specs = [
      {geometry: "gear.obj", saved: "gear-saved-preview.png", source: "gear-preview.ipt", output: "inventor-part.png"},
      {geometry: "gears.obj", saved: "gears-saved-preview.png", source: "gears-preview.iam", output: "inventor-assembly.png"},
      {geometry: "triangle.obj", saved: "fusion-saved-preview.png", source: "fusion-preview.f3d", output: "fusion-saved-preview.png"}
    ]
    results = specs.map do |spec|
      saved = command(binary, inputs.join(spec.fetch(:geometry)), "--output", "-", "--size", "1024", "--samples", "2", "--transparent")
      abort "Expected a 1024px geometry render." unless dimensions(saved) == [1024, 1024]
      inputs.join(spec.fetch(:saved)).binwrite(saved)
      carrier = if spec.fetch(:source).end_with?(".f3d")
        fusion(saved)
      else
        InventorFixture.compound(streams: {"\u0005InventorSummaryInformation" => InventorFixture.property_set(image: saved)})
      end
      source = inputs.join(spec.fetch(:source))
      source.binwrite(carrier)
      extracted = command(binary, source, "--extract-saved-preview", "--output", "-")
      abort "Native extraction changed the saved PNG: #{source}" unless extracted == saved
      thumbnail = command(binary, source, "--output", "-", "--size", "512", "--transparent")
      abort "Expected a 512px extracted thumbnail." unless dimensions(thumbnail) == [512, 512]
      examples.join(spec.fetch(:output)).binwrite(thumbnail)
      {source: source.relative_path_from(root).to_s, geometry: spec.fetch(:geometry),
       native_png: spec.fetch(:saved), native_dimensions: dimensions(extracted),
       native_extraction_exact: extracted == saved, output: spec.fetch(:output),
       output_dimensions: dimensions(thumbnail), source_sha256: Digest::SHA256.hexdigest(carrier),
       native_png_sha256: Digest::SHA256.hexdigest(saved)}
    end
    puts JSON.pretty_generate(catwalk: "2.0.0", render_size: 1024, samples: 2,
      carriers_contain_cad_geometry: false, examples: results)
  end
end

ExamplePreviews.main
