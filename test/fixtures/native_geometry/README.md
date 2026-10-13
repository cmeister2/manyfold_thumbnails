# Native thumbnail integration fixtures

These six original native documents are copied without modification from
[Catwalk's qualified source fixtures](https://github.com/cmeister2/catwalk3d/tree/cc2cbe4395e5df8ef2510a835c3cd9b6f83ea4cf/tests/fixtures).
`provenance.json` retains the original producer repositories, revisions, paths,
byte lengths and SHA-256 digests. The author's MIT license for the Inventor
conveyor and the Fusion author's original license declaration and notice are
retained alongside the files.

The Manyfold tests exercise ordinary attachment promotion with the pinned
Catwalk executable. Inventor parts and the companion-backed conveyor assembly
must produce the same PNG as Catwalk's forced native geometry render. Assembly
promotion is checked on both filesystem and object storage. The Fusion test
removes only PNG members in a temporary copy, verifies every other uncompressed
member byte remains unchanged, then checks automatic missing-image fallback
against forced geometry. Every promoted source attachment must remain unchanged.

The fixtures and their temporary variants never enter the plugin ZIP. CAD
decoding and rendering remain entirely in Catwalk. These tests qualify the
retained native geometry subset; they do not establish every application release,
design-history or assembly-feature variant.
