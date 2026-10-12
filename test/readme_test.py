"""Keep the user-facing supported file list complete as reader support changes."""
from pathlib import Path
import re
import unittest


class ReadmeTest(unittest.TestCase):
    def test_supported_files_match_the_format_registry(self):
        root = Path(__file__).resolve().parents[1]
        formats = (root / "lib/manyfold_thumbnails/formats.rb").read_text(encoding="utf-8")
        extensions = set()
        for constant in ("CATWALK_EXTENSIONS",):
            match = re.search(rf"\b{constant}\s*=\s*%w\[(.*?)\]", formats, re.DOTALL)
            self.assertIsNotNone(match, f"Missing {constant} in the format registry")
            extensions.update(match[1].split())

        readme = (root / "README.md").read_text(encoding="utf-8")
        section = re.search(r"^## Supported files\n(.*?)(?=^## |\Z)", readme, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(section, "Missing the supported files section")
        table = "\n".join(line for line in section[1].splitlines() if line.startswith("|"))
        documented = re.findall(r"`\.([a-z0-9]+)`", table)
        self.assertEqual(len(documented), len(set(documented)), "An extension appears more than once")
        self.assertEqual(set(documented), extensions, "README file types differ from enabled reader support")


if __name__ == "__main__":
    unittest.main()
