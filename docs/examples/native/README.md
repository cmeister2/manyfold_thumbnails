# Native geometry thumbnail sources

These four 512 × 512 PNGs were rendered from unchanged original producer documents by the static Catwalk build in [merged PR #31](https://github.com/cmeister2/catwalk3d/pull/31), at source revision `cc2cbe4395e5df8ef2510a835c3cd9b6f83ea4cf`. The renderer used `--render-geometry --size 512 --transparent --samples 2`, bypassing saved previews. The GitHub Pages demo displays these committed outputs through Manyfold's real model cards. It does not parse or render CAD in the browser.

## Fusion Toy Block

`fusion-toy-block.png` shows Samuel Oladosu's eight-stud toy block from the original `Day#1 - Toy Block v2.f3d` document. The [source notice](fusion-toy-block-NOTICE.txt) retains the input URL and SHA-256. The author's original [README and MIT licensing declaration](FUSION-SAMPLES-README.md) is retained unchanged.

## Fusion Hex Nut

`fusion-hex-nut.png` shows Samuel Oladosu's chamfered hex nut and cylindrical through-bore from the original `Day #6 - Hex Nut v2.f3d`. Cosmetic thread marks are not reconstructed. See the [source notice](fusion-hex-nut-NOTICE.txt) and [original licensing declaration](FUSION-SAMPLES-README.md).

## Inventor box

`inventor-box.png` renders the original conveyor `box.ipt` from [roshbeng/opcua_fusion_test_servers_and_hardware](https://github.com/roshbeng/opcua_fusion_test_servers_and_hardware/tree/d9ab21ced0a26e09a213a218249ac1938340bae6/CAD%20models/conveyor_model/conveyor_model_v1), under the retained [MIT license](LICENSE-roshbeng.txt).

## Inventor conveyor

`inventor-conveyor.png` renders that same author's original `conveyor_model.iam` with its four native `.ipt` companion documents and authored placements. Source URLs, hashes, licenses and independent author-export comparisons are retained in [Catwalk's fixture provenance](https://github.com/cmeister2/catwalk3d/blob/cc2cbe4395e5df8ef2510a835c3cd9b6f83ea4cf/tests/fixtures/native_geometry/inventor/README.md).

These are qualified native geometry examples. They do not establish support for every Inventor or Fusion document variant.
