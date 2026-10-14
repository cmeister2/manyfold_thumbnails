"""Check that Catwalk reader changes require an explicit format registry review."""
import importlib.machinery
import importlib.util
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


FORMATS = """Implemented model readers: stl, obj, bin
Implemented image readers: png, dcm
Saved-preview readers: ipt
Native document geometry readers (qualified subsets): ipt
Fixed-view surface/point/line and image previews. Readers support documented subsets.
Full importer coverage and limitations: docs/format-coverage.md
"""


class CatwalkFormatsTest(unittest.TestCase):
    def test_reader_extensions_are_unioned_across_groups(self):
        self.assertEqual(CHECK.parse_catwalk_formats(FORMATS), {"stl", "obj", "bin", "png", "dcm", "ipt"})

    def test_additional_reader_group_is_checked(self):
        formats = FORMATS + "Additional model readers: new\n"
        self.assertIn("new", CHECK.parse_catwalk_formats(formats))

    def test_explicit_exclusions_allow_known_unsupported_formats(self):
        CHECK.check_formats(CHECK.parse_catwalk_formats(FORMATS), {"stl", "obj", "dcm", "ipt"}, {"png", "bin"})

    def test_new_format_requires_review(self):
        with self.assertRaisesRegex(ValueError, "Unreviewed Catwalk extensions: new"):
            CHECK.check_formats({"stl", "new", "png", "bin"}, {"stl"}, {"png", "bin"})

    def test_new_image_requires_explicit_exclusion_or_support(self):
        with self.assertRaisesRegex(ValueError, "Unreviewed Catwalk extensions: gif"):
            CHECK.check_formats({"stl", "png", "gif", "bin"}, {"stl"}, {"png", "bin"})

    def test_equal_count_change_reports_both_extensions(self):
        with self.assertRaises(ValueError) as error:
            CHECK.check_formats({"obj", "png", "bin"}, {"stl"}, {"png", "bin"})
        self.assertIn("Unreviewed Catwalk extensions: obj", str(error.exception))
        self.assertIn("Registered extensions absent from Catwalk: stl", str(error.exception))

    def test_removed_exclusion_requires_review(self):
        with self.assertRaisesRegex(ValueError, "Excluded extensions absent from Catwalk: png"):
            CHECK.check_formats({"stl", "bin"}, {"stl"}, {"png", "bin"})

    def test_supported_and_excluded_extensions_cannot_overlap(self):
        with self.assertRaisesRegex(ValueError, "Registered and excluded: stl"):
            CHECK.check_formats({"stl", "bin"}, {"stl"}, {"stl", "bin"})

    def test_malformed_output_fails(self):
        for output in ("", "[]", FORMATS.replace("stl, obj, bin", "stl, .obj, bin"),
                       FORMATS.replace("Saved-preview readers: ipt\n", ""),
                       FORMATS + "Saved-preview readers: ipt\n",
                       FORMATS.replace("Saved-preview readers: ipt", "Saved-preview readers: ")):
            with self.subTest(output=output), self.assertRaises(ValueError):
                CHECK.parse_catwalk_formats(output)

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
            self.assertIn("stl", CHECK.catwalk_extensions(Path("/catwalk")))
        self.assertEqual(run.call_args.args[0], ["/catwalk", "--list-formats"])
        self.assertTrue(run.call_args.kwargs["check"])

    def test_binary_failure_reports_stderr(self):
        error = subprocess.CalledProcessError(2, ["catwalk"], stderr="unsupported option\n")
        with patch.object(CHECK.subprocess, "run", side_effect=error), self.assertRaisesRegex(ValueError, "exit 2.*unsupported option"):
            CHECK.catwalk_extensions(Path("/catwalk"))

    def test_selects_binary_for_linux_host_architecture(self):
        for machine, target in (("x86_64", "x86_64"), ("aarch64", "aarch64"), ("arm64", "aarch64")):
            with self.subTest(machine=machine), patch.object(CHECK.platform, "system", return_value="Linux"), patch.object(CHECK.platform, "machine", return_value=machine):
                self.assertEqual(CHECK.host_binary(Path("/plugin")), Path(f"/plugin/test/vendor/catwalk/{target}-unknown-linux-musl/catwalk"))
        with patch.object(CHECK.platform, "system", return_value="Darwin"), self.assertRaisesRegex(ValueError, "supply --binary"):
            CHECK.host_binary(Path("/plugin"))


if __name__ == "__main__":
    unittest.main()
