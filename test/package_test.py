"""Check the release ZIP layout using a disposable plugin checkout."""
from pathlib import Path
import json
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


class PackageTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "bin").mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / "bin/package", self.root / "bin/package")
        self.runtime = {
            "manyfold_thumbnails.gemspec": 'Gem::Specification.new do |spec|\n  spec.version = "0.0.0"\nend\n',
            "app/jobs/manyfold_thumbnails/backfill_job.rb": "# Job\n",
            "config/locales/en.yml": "en: {}\n",
            "db/migrate/create_specialist_preview_backfills.rb": "# Migration\n",
            "lib/manyfold_thumbnails.rb": "# Plugin\n",
            "lib/file_handlers/catwalk_thumbnailer.rb": "# Handler\n",
            "lib/manyfold_thumbnails/executable.rb": "# Downloader\n",
            "lib/tasks/manyfold_thumbnails.rake": "# Tasks\n",
        }
        metadata = {"version": "2.1.0", "repository": "https://github.com/cmeister2/catwalk3d",
                    "targets": ["x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"]}
        self.legacy_vendor = {}
        for target in metadata["targets"]:
            vendor_files = {
                "catwalk": "#!/bin/sh\nexit 0\n",
                "LICENSE": "License\n",
                "THIRD_PARTY_LICENSES.html": "Third-party notices\n",
                "RUST-LICENSES.html": "Rust notices\n",
                "MUSL-COPYRIGHT": "Musl notices\n",
                "release.json": json.dumps({"version": "2.1.0", "target": target, "binary": "catwalk"}),
            }
            for name, content in vendor_files.items():
                self.legacy_vendor[f"lib/manyfold_thumbnails/vendor/{target}/{name}"] = content
        self.runtime["config/catwalk.json"] = json.dumps(metadata)
        for name, content in self.runtime.items():
            self.write(name, content)
        for name, content in self.legacy_vendor.items():
            self.write(name, content)
        (self.root / "lib/manyfold_thumbnails.rb").chmod(0o755)
        for target in metadata["targets"]:
            (self.root / f"lib/manyfold_thumbnails/vendor/{target}/catwalk").chmod(0o755)
        for name in ("README.md", "test/plugin_test.rb", "Dockerfile", "node_modules/package/index.js", ".git/config", "dist/old.zip"):
            self.write(name, "Excluded\n")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def run_package(self, *arguments):
        return subprocess.run([sys.executable, str(self.root / "bin/package"), *arguments], cwd=self.root.parent, capture_output=True, text=True)

    def test_default_version_and_installable_archive(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        output = self.root / "dist/manyfold_thumbnails.zip"
        self.assertEqual(result.stdout.strip(), str(output))
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(set(archive.namelist()), set(self.runtime))
            for name, content in self.runtime.items():
                self.assertEqual(archive.read(name).decode("utf-8"), content)
            self.assertEqual(stat.S_IMODE(archive.getinfo("lib/manyfold_thumbnails.rb").external_attr >> 16), 0o755)
            self.assertFalse(any("/vendor/" in name for name in archive.namelist()))

    def test_release_version_changes_archive_only(self):
        result = self.run_package("1.2.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / "dist/manyfold_thumbnails.zip") as archive:
            expected = self.runtime["manyfold_thumbnails.gemspec"].replace('"0.0.0"', '"1.2.3"')
            self.assertEqual(archive.read("manyfold_thumbnails.gemspec").decode("utf-8"), expected)
        self.assertEqual((self.root / "manyfold_thumbnails.gemspec").read_text(encoding="utf-8"), self.runtime["manyfold_thumbnails.gemspec"])

    def test_upgrade_replaces_the_same_package(self):
        (self.root / "dist/old.zip").unlink()
        for version in ("0.1.0", "1.2.3"):
            result = self.run_package(version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(list((self.root / "dist").iterdir()), [self.root / "dist/manyfold_thumbnails.zip"])
            with zipfile.ZipFile(self.root / "dist/manyfold_thumbnails.zip") as archive:
                expected = self.runtime["manyfold_thumbnails.gemspec"].replace('"0.0.0"', f'"{version}"')
                self.assertEqual(archive.read("manyfold_thumbnails.gemspec").decode("utf-8"), expected)
            self.assertEqual((self.root / "manyfold_thumbnails.gemspec").read_text(encoding="utf-8"), self.runtime["manyfold_thumbnails.gemspec"])

    def test_invalid_versions_create_no_package(self):
        for version in ("01.2.3", "1.2", "v1.2.3", "1.2.3-beta.1", "../1.2.3", "1.2.3/other"):
            with self.subTest(version=version):
                result = self.run_package(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VERSION must be", result.stderr)
        self.assertEqual(list((self.root / "dist").iterdir()), [self.root / "dist/old.zip"])

    def test_packaging_needs_no_local_binary_or_network(self):
        shutil.rmtree(self.root / "lib/manyfold_thumbnails/vendor")
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / "dist/manyfold_thumbnails.zip") as archive:
            self.assertEqual(set(archive.namelist()), set(self.runtime))

    def test_legacy_binary_and_notices_are_excluded_even_when_modified(self):
        for name in ("catwalk", "LICENSE", "RUST-LICENSES.html", "THIRD_PARTY_LICENSES.html", "MUSL-COPYRIGHT", "release.json"):
            path = f"lib/manyfold_thumbnails/vendor/x86_64-unknown-linux-musl/{name}"
            with self.subTest(name=name):
                self.write(path, "Changed\n")
                result = self.run_package()
                self.assertEqual(result.returncode, 0, result.stderr)
                with zipfile.ZipFile(self.root / "dist/manyfold_thumbnails.zip") as archive:
                    self.assertNotIn(path, archive.namelist())
                self.write(path, self.legacy_vendor[path])

    def test_test_assets_are_never_packaged(self):
        self.write("test/vendor/catwalk/x86_64-unknown-linux-musl/catwalk", "Test asset\n")
        (self.root / "lib/manyfold_thumbnails/vendor/x86_64-unknown-linux-musl/catwalk").chmod(0o644)
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(self.root / "dist/manyfold_thumbnails.zip") as archive:
            self.assertEqual(set(archive.namelist()), set(self.runtime))


if __name__ == "__main__":
    unittest.main()
