# frozen_string_literal: true

require_relative "inventor_fixture"

# Small authored inputs without companion files. Saved-preview carriers follow
# Catwalk 2.3.2's qualified framing; they are not complete native CAD documents.
module CatwalkFixture
  OBJ = "v 0 0 0\nv 10 0 0\nv 0 10 0\nv 0 0 10\nf 1 2 3\nf 1 2 4\nf 1 3 4\nf 2 3 4\n".freeze
  LIGHTBURN = <<~XML.freeze
    <LightBurnProject FormatVersion="1" MirrorX="False" MirrorY="False">
      <Shape Type="Rect" CutIndex="0" W="10" H="10" Cr="0">
        <XForm>1 0 0 1 5 5</XForm>
      </Shape>
    </LightBurnProject>
  XML
  PCD = <<~PCD.freeze
    VERSION .7
    FIELDS x y z
    SIZE 4 4 4
    TYPE F F F
    COUNT 1 1 1
    WIDTH 4
    HEIGHT 1
    VIEWPOINT 0 0 0 1 0 0 0
    POINTS 4
    DATA ascii
    0 0 0
    10 0 0
    0 10 0
    0 0 10
  PCD

  module_function

  def solidworks
    InventorFixture.compound(streams: {
      "ISolidWorksInformation" => "\xfe\xff".b,
      "PreviewPNG" => InventorFixture.png
    }, mini: true)
  end

  def rhino
    # Rhino archive 4 uses four-byte chunk lengths. The addressed bitmap has
    # its own CRC and the document-properties table ends with a short marker.
    dib = InventorFixture.dib
    preview = [0x20008023, dib.bytesize + 4].pack("V2") + dib + [Zlib.crc32(dib)].pack("V")
    properties = preview + [0xffffffff, 0].pack("V2")
    "3D Geometry File Format        4".b + [1, 0, 0x10000014, properties.bytesize].pack("V4") + properties
  end

  def sketchup
    image = InventorFixture.png
    sketchup_string("SketchUp Model") + sketchup_string("{16.0.0}") + "\0".b * 16 +
      sketchup_string("") + [0].pack("V") + sketchup_class("CVersionMap", 0) +
      sketchup_string("CDib") + [3].pack("V") + sketchup_string("End-Of-Version-Map") +
      [0, 2, 1200, 6].pack("V4") + sketchup_class("CDib", 3) + [4, image.bytesize].pack("V2") + image
  end

  def max
    # One full-size SRCCOPY DIB in a WMF, wrapped as CF_METAFILEPICT in the
    # SummaryInformation PID 17 property. Scene streams qualify the container.
    dib = InventorFixture.dib
    record_words = (28 + dib.bytesize) / 2
    record = [record_words, 0x0f43, 0x00cc0020, 0, 2, 2, 0, 0, 2, 2, 0, 0].pack("VvVv9") + dib
    wmf = [1, 9, 0x300, 9 + record_words + 3, 0, record_words, 0].pack("v3VvVv") +
      record + [3, 0].pack("Vv")
    clipboard = [InventorFixture::FREE, 3].pack("V2") + [1, 2, 2, 0].pack("v4")
    summary = InventorFixture.property_set(image: wmf, fmtid: :summary, clipboard: clipboard)
    InventorFixture.compound(streams: {
      "Scene" => "".b, "ClassData" => "".b, "ClassDirectory3" => "".b,
      "\u0005SummaryInformation" => summary
    }, mini: true)
  end

  def sketchup_string(value)
    "\xff\xfe\xff".b + [value.length].pack("C") + value.encode("UTF-16LE").b
  end
  private_class_method :sketchup_string

  def sketchup_class(name, schema)
    [0xffff, schema, name.bytesize].pack("v3") + name.b
  end
  private_class_method :sketchup_class
end
