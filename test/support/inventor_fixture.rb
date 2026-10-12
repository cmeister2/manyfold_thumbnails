# frozen_string_literal: true

require "zlib"

# Small, generated CFB/OLEPS inputs. These exercise container layouts without
# redistributing somebody else's CAD model; they are not Inventor documents.
module InventorFixture
  FREE = 0xffffffff
  END_OF_CHAIN = 0xfffffffe
  FAT_SECTOR = 0xfffffffd
  INVENTOR_FMTID = "3d38de39-0588-4c14-bb37-18f4d5dd31c7"
  SUMMARY_FMTID = "f29f85e0-4ff9-1068-ab91-08002b27b3d9"

  module_function

  def guid(value)
    pieces = value.split("-")
    [pieces[0].to_i(16), pieces[1].to_i(16), pieces[2].to_i(16)].pack("Vvv") +
      [pieces[3] + pieces[4]].pack("H*")
  end

  def chunk(type, data)
    [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
  end

  def png(width: 2, height: 2, color: [255, 0, 0, 128])
    scanline = "\0".b + color.pack("C*") * width
    "\x89PNG\r\n\x1a\n".b +
      chunk("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNC5")) +
      chunk("IDAT", Zlib.deflate(scanline * height)) + chunk("IEND", "".b)
  end

  def dib(width: 2, height: 2, color: [0, 0, 255])
    row = (color.pack("C*") * width).ljust(((width * 3 + 3) / 4) * 4, "\0")
    [40, width, height, 1, 24, 0, row.bytesize * height, 0, 0, 0, 0].pack("Vl<l<vvV6") + row * height
  end

  def bmp(**options)
    body = dib(**options)
    "BM".b + [14 + body.bytesize, 0, 54].pack("V3") + body
  end

  # The Inventor wrapper matches the observed prefix in two real 2027 files.
  # :dib uses the OLEPS standard Windows CF_DIB wrapper. :raw is useful for
  # checking that a bare image is not mistaken for a clipboard value.
  def property_set(image: png, fmtid: :inventor, clipboard: :inventor, pid: 17, type: 71)
    format = case fmtid
    when :inventor then INVENTOR_FMTID
    when :summary then SUMMARY_FMTID
    else fmtid
    end
    prefix = case clipboard
    when :inventor
      width, height = if image.start_with?("\x89PNG\r\n\x1a\n".b)
        image.byteslice(16, 8).unpack("N2")
      elsif image.start_with?("BM")
        image.byteslice(18, 8).unpack("l<2")
      elsif image.bytesize >= 12
        image.byteslice(4, 8).unpack("l<2")
      else
        [512, 512]
      end
      [FREE, 3].pack("V2") + [8, width, height.abs, 0].pack("v4")
    when :dib then [FREE, 8].pack("V2")
    when :png then [4].pack("V") + "PNG\0".b
    when :raw then "".b
    else clipboard.b
    end
    blob = prefix + image
    typed_value = [type, blob.bytesize].pack("V2") + blob
    typed_value = typed_value.ljust((typed_value.bytesize + 3) & ~3, "\0")
    section = [16 + typed_value.bytesize, 1, pid, 16].pack("V4") + typed_value
    [0xfffe, 0, 0x00020006].pack("vvV") + "\0".b * 16 +
      [1].pack("V") + guid(format) + [48].pack("V") + section
  end

  # Streams are supplied as path => bytes. Slash paths create storage entries;
  # e.g. {"MemberDocs/nested/preview" => property_set} is a distractor thumbnail.
  # mini:false pads short streams to 4096 bytes to force ordinary FAT storage.
  # mini:true stores streams smaller than the cutoff through miniFAT.
  def compound(streams:, mini: false, sector_size: 512, root_clsid: nil)
    raise ArgumentError, "sector size must be 512 or 4096" unless [512, 4096].include?(sector_size)

    nodes = [{name: "Root Entry", type: 5, children: [], left: FREE, right: FREE, child: FREE,
              start: END_OF_CHAIN, size: 0}]
    paths = {"" => 0}
    streams.each do |path, content|
      parts = path.split("/")
      parent = 0
      parts.each_with_index do |name, index|
        location = parts.take(index + 1).join("/")
        if paths.key?(location)
          parent = paths.fetch(location)
          next
        end
        id = nodes.length
        terminal = index == parts.length - 1
        nodes << {name: name, type: terminal ? 2 : 1, children: [], left: FREE, right: FREE,
                  child: FREE, start: END_OF_CHAIN, size: 0, data: terminal ? content.b : nil}
        nodes[parent][:children] << id
        paths[location] = id
        parent = id
      end
    end

    build_tree = lambda do |ids|
      next FREE if ids.empty?

      midpoint = ids.length / 2
      id = ids[midpoint]
      nodes[id][:left] = build_tree.call(ids.take(midpoint))
      nodes[id][:right] = build_tree.call(ids.drop(midpoint + 1))
      id
    end
    nodes.each do |node|
      node[:child] = build_tree.call(node[:children].sort_by { |id| [nodes[id][:name].length, nodes[id][:name].upcase] })
    end

    sectors = []
    links = []
    allocate = lambda do |bytes|
      next END_OF_CHAIN if bytes.empty?

      start = sectors.length
      count = (bytes.bytesize + sector_size - 1) / sector_size
      count.times do |index|
        sectors << bytes.byteslice(index * sector_size, sector_size).ljust(sector_size, "\0")
        links << (index == count - 1 ? END_OF_CHAIN : start + index + 1)
      end
      start
    end
    minidata = "".b
    minilinks = []
    nodes.select { |node| node[:type] == 2 }.each do |node|
      bytes = node[:data]
      if mini && bytes.bytesize < 4096 && !bytes.empty?
        node[:start] = minilinks.length
        node[:size] = bytes.bytesize
        count = (bytes.bytesize + 63) / 64
        count.times do |index|
          minidata << bytes.byteslice(index * 64, 64).ljust(64, "\0")
          minilinks << (index == count - 1 ? END_OF_CHAIN : minilinks.length + 1)
        end
      else
        bytes = bytes.ljust(4096, "\0") if !bytes.empty? && bytes.bytesize < 4096
        node[:start] = allocate.call(bytes)
        node[:size] = bytes.bytesize
      end
    end
    nodes[0][:start] = allocate.call(minidata)
    nodes[0][:size] = minidata.bytesize
    minifat = minilinks.pack("V*")
    minifat = minifat.ljust(((minifat.bytesize + sector_size - 1) / sector_size) * sector_size, "\xff".b)
    minifat_start = allocate.call(minifat)

    entries = nodes.each_with_index.map do |node, index|
      entry = "\0".b * 128
      name = (node[:name] + "\0").encode("UTF-16LE").b
      raise ArgumentError, "directory name too long" if name.bytesize > 64

      entry[0, name.bytesize] = name
      entry[64, 2] = [name.bytesize].pack("v")
      entry[66, 2] = [node[:type], 1].pack("C2")
      entry[68, 12] = [node[:left], node[:right], node[:child]].pack("V3")
      entry[80, 16] = guid(root_clsid) if index.zero? && root_clsid
      entry[116, 12] = [node[:start], node[:size]].pack("VQ<")
      entry
    end.join
    directory_start = allocate.call(entries)
    directory_count = (entries.bytesize + sector_size - 1) / sector_size
    per_fat = sector_size / 4
    fat_count = 1
    loop do
      required = (sectors.length + fat_count + per_fat - 1) / per_fat
      break if required == fat_count

      fat_count = required
    end
    raise ArgumentError, "fixture requires DIFAT" if fat_count > 109

    fat_ids = (sectors.length...(sectors.length + fat_count)).to_a
    links += [FAT_SECTOR] * fat_count
    fat_bytes = links.pack("V*").ljust(fat_count * sector_size, "\xff".b)
    fat_count.times { |index| sectors << fat_bytes.byteslice(index * sector_size, sector_size) }

    header = "\0".b * sector_size
    header[0, 8] = "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1".b
    header[24, 10] = [0x003e, sector_size == 512 ? 3 : 4, 0xfffe,
                      sector_size == 512 ? 9 : 12, 6].pack("v5")
    header[40, 36] = [sector_size == 512 ? 0 : directory_count, fat_count, directory_start,
                      0, 4096, minifat_start, minifat.bytesize / sector_size, END_OF_CHAIN, 0].pack("V9")
    header[76, 436] = (fat_ids + [FREE] * (109 - fat_ids.length)).pack("V*")
    header + sectors.join
  end
end
