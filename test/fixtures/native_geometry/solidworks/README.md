# SolidWorks assembly qualification

`bin/fetch-test-solidworks` downloads original MIT-licensed Power Package documents byte for byte from
[Catwalk 2.4.0](https://github.com/cmeister2/catwalk3d/tree/7bc0d96320b72a05c6ed44fbfaab4be0eef69d5f/tests/fixtures/formats/solidworks).
The retained upstream provenance files record the producer repository, revision,
source filenames, hashes, geometry bounds and nine placed part occurrences.
`POWER-PACKAGE-LICENSE.txt` retains the author's license.

Downloaded assets live in ignored `test/vendor/catwalk/solidworks` and are mounted
under `/test-catwalk/solidworks` for network-isolated container tests. No CAD
binaries are committed or packaged.

`no-preview.sldasm` is a test-only copy of `solidworks-powerpackage.sldasm`.
Only the contents of the root `Preview` and `PreviewPNG` streams are overwritten
with zero bytes; their lengths and every other stream are unchanged. This makes
both saved images unusable while preserving the native geometry records. It is
not a new producer-authored model. `qualification.json` records both original
and derivative hashes. To reproduce it with Python's `olefile` package:

```python
import olefile, shutil
shutil.copyfile("solidworks-powerpackage.sldasm", "no-preview.sldasm")
with olefile.OleFileIO("no-preview.sldasm", write_mode=True) as document:
    for name in ("Preview", "PreviewPNG"):
        document.write_stream(name, b"\0" * document.get_size(name))
```

The native tests compare automatic rendering of this copy against forced
geometry rendering of the unmodified assembly. They exercise an original local
project, an isolated source with attachment downloads, missing parts, duplicate
names and unsafe paths. Manyfold workflow tests additionally exercise normal
background promotion on filesystem and Shrine object storage. The shared
staging tests cover nested paths and `.sldasm` attachments, size/deadline bounds,
cleanup and Inventor regressions. This producer fixture contains sibling parts,
not a nested producer assembly; it does not qualify every SolidWorks structure.

Run the standalone qualification after `bin/fetch-test-catwalk` and
`bin/fetch-test-solidworks` (both are invoked by `bin/test`):

```sh
MANYFOLD_THUMBNAILS_NATIVE_CATWALK="$PWD/test/vendor/catwalk/x86_64-unknown-linux-musl/catwalk" ruby test/solidworks_native_test.rb
```

Fixtures never enter the plugin ZIP.
