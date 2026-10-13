# Manyfold card examples and thumbnail sources

The main README shows browser screenshots of complete model cards from the released Manyfold 0.151.0 image, using its normal HTML, CSS and render-derivative routes. The titles and filenames are example metadata saved in Manyfold. Screenshots use Chromium in the default light theme at a 1920 x 1200 viewport and twice the display resolution. Each `*-card.png` includes the preview, title, filename caption and action buttons.

The original 512 x 512 thumbnail PNGs remain the inputs for these screenshots. The Lychee image was supplied from an existing Manyfold library; the other five were generated with the plugin's pinned Catwalk 2.0.0 executable. Inventor and Fusion use its thumbnail arguments:

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

## Regenerate the cards

Use a separate development instance for the six example models:

```sh
docker compose -p manyfold-thumbnail-examples up --build -d
docker compose -p manyfold-thumbnail-examples exec manyfold \
  bundle exec rails runner /plugins/manyfold_thumbnails/docs/examples/seed.rb
uv run --with playwright==1.63.0 python -m playwright install chromium
uv run --with playwright==1.63.0 python docs/examples/capture.py \
  --base-url http://127.0.0.1:3215
docker compose -p manyfold-thumbnail-examples down -v
```

The seed imports the committed PNGs as real `render` derivatives and selects their files as model previews. It does not regenerate the thumbnails. It attaches the five original source fixtures when their paths from the table above are available under `FIXTURES_ROOT` (default `/fixtures`). Sources are optional for these display examples; absent sources are represented by derivative-only attachments. In particular, the Avacyn `.lys` was not supplied, so no replacement design file is created.

The capture script visits Manyfold's model list, dismisses the onboarding tour through its close button, waits for fonts and all six render images, checks each title and filename, then screenshots the complete `.card.preview-card` elements. The screenshots are cropped by the browser to the card bounds without changing Manyfold's markup or styling.
