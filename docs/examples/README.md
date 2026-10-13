# Manyfold card examples and thumbnail sources

The main README shows browser screenshots of complete model cards from the released Manyfold 0.151.0 image, using its normal HTML, CSS and render-derivative routes. The titles and filenames are example metadata saved in Manyfold. Screenshots use Chromium in the default light theme with cards measuring 360 CSS pixels, matching their desktop README display width. Capturing at twice the display resolution keeps the text sharp on high-density screens. The gallery wraps into one column on narrower screens. Each `*-card.png` includes the preview, title, filename caption and action buttons.

The cards use 512 x 512 thumbnail PNGs. The Lychee image was supplied from an existing Manyfold library; the other five were generated with Catwalk. The plugin's current release pin is recorded in [the download manifest](../../config/catwalk.json). Inventor and Fusion use its thumbnail arguments:

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
| `inventor-part.png` | [Authored `gear-preview.ipt`](inputs/gear-preview.ipt) | Saved 1024 x 1024 gear image |
| `inventor-assembly.png` | [Authored `gears-preview.iam`](inputs/gears-preview.iam) | Saved 1024 x 1024 two-gear image |
| `fusion-saved-preview.png` | [Authored `fusion-preview.f3d`](inputs/fusion-preview.f3d) | Saved 1024 x 1024 active-design image |
| `lightburn-legacy.png` | [Catwalk's `classic-geometry.lbrn`](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/tests/fixtures/native_geometry/lightburn/classic-geometry.lbrn) | Rendered vector geometry |
| `lightburn-project.png` | [`butterfly_vectorized.lbrn2` from jlucaso1/lbrn2-to-svg](https://github.com/jlucaso1/lbrn2-to-svg/blob/7cea0bf68b7caf4ad8d9b16ea03bd8a90c2c9c49/tests/artifacts/butterfly_vectorized.lbrn2) | Rendered vector geometry |

The Inventor and Fusion inputs are authored thumbnail-container fixtures. They contain saved images without CAD geometry, demonstrating the extraction path used for those formats. Their saved images are rendered at 1024 x 1024 before Catwalk extracts and fits them to 512 x 512 thumbnails. The part uses [Catwalk's MIT-licensed procedural gear](https://github.com/cmeister2/catwalk3d/blob/ddfa03730888e933142f47ad56405ac72903854a/examples/models/gear.obj), retained as [gear.obj](inputs/gear.obj). The assembly duplicates and places that geometry; the Fusion image uses an authored coloured triangular prism. These example inputs retain the [MIT license](LICENSE-catwalk.txt).

The earlier upstream parser fixtures embedded much smaller images: 160 x 128 for the Inventor part, 280 x 160 for its assembly and 192 x 128 for Fusion. Enlarging those saved images made the previous README examples soft. A larger screenshot cannot restore missing source detail; the current examples use new high-resolution carriers. Thumbnails from other files remain limited by the detail in their saved image.

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

The seed imports the committed PNGs as real `render` derivatives and selects their files as model previews. It does not regenerate the thumbnails. It attaches the three committed saved-preview carriers automatically. The two LightBurn source fixtures are attached when available under `FIXTURES_ROOT` (default `/fixtures`). Absent sources are represented by derivative-only attachments. In particular, the Avacyn `.lys` was not supplied, so no replacement design file is created.

The capture script visits Manyfold's model list, dismisses the onboarding tour through its close button, waits for fonts and all six render images, checks each title and filename, then screenshots the complete `.card.preview-card` elements. The screenshots are cropped by the browser to the card bounds without changing Manyfold's markup or styling.

## Regenerate the saved-preview inputs

The committed carriers and PNGs are sufficient for card captures. To rebuild the three authored saved-preview examples, fetch the pinned Catwalk executable and run the generator using Manyfold's Ruby environment:

```sh
python3 bin/fetch-test-catwalk
docker run --rm --entrypoint /bin/ash \
  --mount "type=bind,source=$PWD,target=/examples" \
  manyfold3d/manyfold-solo:0.151.0@sha256:772bcb18f0cb69d4fd0630d4676516f34fb37e42c3ac9d65eea5f173728e818e \
  -ec 'bundle exec ruby /examples/docs/examples/generate-previews.rb'
```

The generator renders the original example geometry at 1024 x 1024, embeds those PNGs in the new carriers, verifies that Catwalk's saved-preview extraction preserves their bytes, and generates the normal 512 x 512 thumbnails. It does not modify the upstream Catwalk fixtures.
