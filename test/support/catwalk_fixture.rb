# frozen_string_literal: true

# Small authored geometry inputs; these need no companion files or saved images.
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
end
