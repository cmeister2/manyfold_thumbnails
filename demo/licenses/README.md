# Demo asset notices

The demo build script, export pipeline and static navigation helpers adapt
[Max Dymond's OpenSCAD demo](https://github.com/cmeister2/manyfold_openscad/tree/41a967e1d76fd10924cce1f2605e0422c81bcf5e).
Its original **Copyright (C) 2026 Max Dymond** notice and exact source files are
retained in [OPENSCAD-DEMO-NOTICE.txt](OPENSCAD-DEMO-NOTICE.txt), with the original
[AGPL-3.0-only license](OPENSCAD-DEMO-AGPL-3.0.txt). This identifies the license
of the adapted demo code, without declaring a license for the whole thumbnail
plugin repository.

The demo uses Manyfold 0.151.0's default compiled stylesheet and its icon fonts.
These files preserve the upstream license texts and notices for those assets.
Dependency versions come from `yarn.lock` in the pinned Docker image, rather
than the ranges in its `package.json`.

| Asset | Version | Notice |
| --- | --- | --- |
| Manyfold stylesheet | 0.151.0 | [AGPL-3.0](manyfold-LICENSE.md) |
| Bootstrap CSS | 5.3.8 | [MIT](bootstrap-LICENSE.txt) |
| Bootstrap Icons CSS and fonts | 1.13.1 | [MIT](bootstrap-icons-LICENSE.txt) |
| RPG Awesome Continued CSS and font | 1.0.6 | [Upstream license](rpg-awesome-continued-LICENSE.md), [notice](rpg-awesome-continued-NOTICE.txt), [README](rpg-awesome-continued-README.md) |
| Tom Select CSS | 2.6.2 | [Apache-2.0](tom-select-LICENSE.txt) |
| Uppy Core CSS | 6.2.0 | [MIT](uppy-core-LICENSE.txt) |
| Uppy Dashboard CSS | 5.1.0 | [MIT](uppy-dashboard-LICENSE.txt) |
| driver.js CSS | 1.9.0 | [MIT](driverjs-LICENSE.txt) |

RPG Awesome Continued is by Miguel Rodríguez, Daniela Howe and Ivan Montiel,
using icons from [Game Icons](https://game-icons.net/). Its package includes a
BSD-style `LICENSE.md`; its README and stylesheet identify the CSS as MIT, the
font as SIL OFL 1.1, and its documentation as CC BY 3.0. The original notices
are retained together with the full [MIT](MIT.txt), [OFL 1.1](OFL-1.1.txt), and
[CC BY 3.0](CC-BY-3.0.txt) texts.

[manifest.json](manifest.json) records each exact package download, version and
upstream repository, along with the pinned Manyfold image and
[stylesheet source](https://github.com/manyfold3d/manyfold/tree/c89c8964c714749957656474ab1e3757ff8f12ca).
The exporter checks each declared package version against that image's
`yarn.lock` and checks the host source revision before publishing. The updated
Uppy Core and driver.js licenses were copied from their exact npm archives,
verified against the registry's SHA-512 integrity values.

The export copies this directory to the published demo with the adapted demo
code's notices, Manyfold's AGPL license and the committed thumbnail
examples' retained notices. No host
JavaScript, CAD parser, renderer or WebAssembly runtime is distributed by this
demo.
