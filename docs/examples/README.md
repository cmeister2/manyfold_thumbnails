# Thumbnail example sources

The main README uses these unmodified 512 × 512 PNG outputs. The Lychee image was supplied from an existing Manyfold library; the other five were generated with the plugin's pinned Catwalk 2.0.0 executable. Inventor and Fusion use its thumbnail arguments:

```sh
catwalk INPUT --output - --size 512 --transparent > OUTPUT.png
```

The LightBurn examples use a white canvas so their outlines remain visible on light and dark README backgrounds:

```sh
catwalk INPUT --output - --size 512 --background ffffff > OUTPUT.png
```

| Image | Input and source | Thumbnail source |
| --- | --- | --- |
| `lychee-avacyn-bust.png` | `Avacyn_Bust.lys`, preview shared by the repository maintainer | Existing Manyfold render |
| `inventor-part.png` | [Catwalk's `part-carrier.ipt`](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/tests/fixtures/saved-previews/autodesk/part-carrier.ipt) | Saved gear image |
| `inventor-assembly.png` | [Catwalk's `assembly-carrier.iam`](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/tests/fixtures/saved-previews/autodesk/assembly-carrier.iam) | Saved two-gear image |
| `fusion-saved-preview.png` | [Catwalk's `fusion-authored-deflate-preview.f3d`](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/tests/fixtures/formats/saved_previews/fusion-authored-deflate-preview.f3d) | Saved active-design image |
| `lightburn-legacy.png` | [Catwalk's `classic-geometry.lbrn`](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/tests/fixtures/native_geometry/lightburn/classic-geometry.lbrn) | Rendered vector geometry |
| `lightburn-project.png` | [`butterfly_vectorized.lbrn2` from jlucaso1/lbrn2-to-svg](https://github.com/jlucaso1/lbrn2-to-svg/blob/7cea0bf68b7caf4ad8d9b16ea03bd8a90c2c9c49/tests/artifacts/butterfly_vectorized.lbrn2) | Rendered vector geometry |

The Inventor and Fusion inputs are authored thumbnail-container fixtures. They contain saved images without CAD geometry, demonstrating the extraction path used for those formats. Catwalk's original gear model and these authored fixtures are covered by its [MIT license](LICENSE-catwalk.txt).

The butterfly project is from João Lucas de Oliveira Lopes's lbrn2-to-svg project, used under its [MIT license](LICENSE-lightburn-project.txt).
