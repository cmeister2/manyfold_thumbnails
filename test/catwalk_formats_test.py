"""Check that Catwalk reader changes require an explicit format registry review."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "bin/check-catwalk-formats"
LOADER = importlib.machinery.SourceFileLoader("check_catwalk_formats", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
CHECK = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(CHECK)


VERSION = "2.4.0"
CATALOG = {
    "schema_version": 1,
    "catwalk_version": VERSION,
    "extensions": ["bin", "dcm", "ipt", "obj", "png", "stl"],
    "formats": [{"extension": extension, "description": f"{extension.upper()} format"}
                for extension in ("bin", "dcm", "ipt", "obj", "png", "stl")],
    "categories": {
        "geometry": ["bin", "ipt", "obj", "stl"],
        "image": ["dcm", "png"],
        "saved_preview": ["ipt"],
        "native_geometry": ["ipt"],
    },
}
FORMATS = json.dumps(CATALOG)


class CatwalkFormatsTest(unittest.TestCase):
    def test_reads_complete_extension_catalog_including_aliases_and_overlapping_categories(self):
        self.assertEqual(CHECK.parse_catwalk_formats(FORMATS, VERSION), {"stl", "obj", "bin", "png", "dcm", "ipt"})

    def test_additional_metadata_is_ignored(self):
        catalog = {**CATALOG, "documentation": "https://example.com/formats"}
        catalog["categories"] = {**CATALOG["categories"], "additional": ["stl"]}
        self.assertEqual(CHECK.parse_catwalk_formats(json.dumps(catalog), VERSION), set(CATALOG["extensions"]))

    def test_explicit_exclusions_allow_known_unsupported_formats(self):
        CHECK.check_formats(CHECK.parse_catwalk_formats(FORMATS, VERSION), {"stl", "obj", "dcm", "ipt"}, {"png", "bin"})

    def test_new_format_requires_review(self):
        catalog = {**CATALOG, "extensions": ["bin", "new", "png", "stl"]}
        with self.assertRaisesRegex(ValueError, "Unreviewed Catwalk extensions: new"):
            CHECK.check_formats(CHECK.parse_catwalk_formats(json.dumps(catalog), VERSION), {"stl"}, {"png", "bin"})

    def test_new_image_requires_explicit_exclusion_or_support(self):
        with self.assertRaisesRegex(ValueError, "Unreviewed Catwalk extensions: gif"):
            CHECK.check_formats({"stl", "png", "gif", "bin"}, {"stl"}, {"png", "bin"})

    def test_equal_count_change_reports_both_extensions(self):
        catalog = {**CATALOG, "extensions": ["bin", "obj", "png"]}
        with self.assertRaises(ValueError) as error:
            CHECK.check_formats(CHECK.parse_catwalk_formats(json.dumps(catalog), VERSION), {"stl"}, {"png", "bin"})
        self.assertIn("Unreviewed Catwalk extensions: obj", str(error.exception))
        self.assertIn("Registered extensions absent from Catwalk: stl", str(error.exception))

    def test_removed_exclusion_requires_review(self):
        with self.assertRaisesRegex(ValueError, "Excluded extensions absent from Catwalk: png"):
            CHECK.check_formats({"stl", "bin"}, {"stl"}, {"png", "bin"})

    def test_supported_and_excluded_extensions_cannot_overlap(self):
        with self.assertRaisesRegex(ValueError, "Registered and excluded: stl"):
            CHECK.check_formats({"stl", "bin"}, {"stl"}, {"stl", "bin"})

    def test_malformed_output_fails(self):
        for output in ("", "[]", "null", "Implemented model readers: stl\n", FORMATS + FORMATS):
            with self.subTest(output=output), self.assertRaises(ValueError):
                CHECK.parse_catwalk_formats(output, VERSION)

    def test_unsupported_or_missing_schema_fails(self):
        for schema in (None, 0, 2, "1", 1.0, True):
            with self.subTest(schema=schema), self.assertRaisesRegex(ValueError, "schema_version"):
                CHECK.parse_catwalk_formats(json.dumps({**CATALOG, "schema_version": schema}), VERSION)
        with self.assertRaisesRegex(ValueError, "schema_version"):
            CHECK.parse_catwalk_formats("{}", VERSION)

    def test_binary_version_must_match_pin(self):
        for version in (None, "2.3.2", 2.4):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "does not match pinned version"):
                CHECK.parse_catwalk_formats(json.dumps({**CATALOG, "catwalk_version": version}), VERSION)

    def test_invalid_extension_array_fails(self):
        for extensions in (None, "stl", [None], [1], [True], [""], [".stl"], ["STL"], ["stl\n"],
                           ["stl", "stl"], ["stl", "obj"]):
            with self.subTest(extensions=extensions), self.assertRaisesRegex(ValueError, "extensions"):
                CHECK.parse_catwalk_formats(json.dumps({**CATALOG, "extensions": extensions}), VERSION)

    def test_empty_catalog_reports_missing_registered_and_excluded_extensions(self):
        upstream = CHECK.parse_catwalk_formats(json.dumps({**CATALOG, "extensions": []}), VERSION)
        with self.assertRaises(ValueError) as error:
            CHECK.check_formats(upstream, {"stl"}, {"bin"})
        self.assertIn("Registered extensions absent from Catwalk: stl", str(error.exception))
        self.assertIn("Excluded extensions absent from Catwalk: bin", str(error.exception))

    def test_reads_supported_and_excluded_lists_from_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "formats.rb"
            registry.write_text("CATWALK_EXTENSIONS = %w[stl obj].freeze\nCATWALK_EXCLUDED_EXTENSIONS = %w[png bin].freeze\n", encoding="utf-8")
            self.assertEqual(CHECK.read_registry(registry), [{"stl", "obj"}, {"png", "bin"}])

    def test_invalid_registry_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "formats.rb"
            for source in ("CATWALK_EXTENSIONS = %w[stl].freeze",
                           "CATWALK_EXTENSIONS = %w[stl stl].freeze\nCATWALK_EXCLUDED_EXTENSIONS = %w[bin].freeze",
                           "CATWALK_EXTENSIONS = %w[.stl].freeze\nCATWALK_EXCLUDED_EXTENSIONS = %w[bin].freeze"):
                with self.subTest(source=source), self.assertRaises(ValueError):
                    registry.write_text(source, encoding="utf-8")
                    CHECK.read_registry(registry)

    def test_runs_binary_format_registry_without_rendering(self):
        result = subprocess.CompletedProcess([], 0, stdout=FORMATS, stderr="")
        with patch.object(CHECK.subprocess, "run", return_value=result) as run:
            self.assertIn("stl", CHECK.catwalk_extensions(Path("/catwalk"), VERSION))
        self.assertEqual(run.call_args.args[0], ["/catwalk", "--list-formats", "--json"])
        self.assertTrue(run.call_args.kwargs["check"])

    def test_binary_failure_reports_stderr(self):
        error = subprocess.CalledProcessError(2, ["catwalk"], stderr="unsupported option\n")
        with patch.object(CHECK.subprocess, "run", side_effect=error), self.assertRaisesRegex(ValueError, "exit 2.*unsupported option"):
            CHECK.catwalk_extensions(Path("/catwalk"), VERSION)

    def test_selects_binary_for_linux_host_architecture(self):
        for machine, target in (("x86_64", "x86_64"), ("aarch64", "aarch64"), ("arm64", "aarch64")):
            with self.subTest(machine=machine), patch.object(CHECK.platform, "system", return_value="Linux"), patch.object(CHECK.platform, "machine", return_value=machine):
                self.assertEqual(CHECK.host_binary(Path("/plugin")), Path(f"/plugin/test/vendor/catwalk/{target}-unknown-linux-musl/catwalk"))
        with patch.object(CHECK.platform, "system", return_value="Darwin"), self.assertRaisesRegex(ValueError, "supply --binary"):
            CHECK.host_binary(Path("/plugin"))


if __name__ == "__main__":
    unittest.main()
