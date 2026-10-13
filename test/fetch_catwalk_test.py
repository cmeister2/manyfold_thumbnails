"""Exercise release metadata downloads and offline Catwalk test asset checks."""
import copy
import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "bin/fetch-test-catwalk"
LOADER = importlib.machinery.SourceFileLoader("fetch_test_catwalk", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
fetch = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(fetch)


class FetchCatwalkTest(unittest.TestCase):
    VERSION = "2.1.0"
    TARGET = "x86_64-unknown-linux-musl"
    REPOSITORY = "https://github.com/example/catwalk3d"

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.vendor = self.root / "test/vendor/catwalk"
        self.destination = self.vendor / self.TARGET
        self.manifest, self.archive, self.files = self.release_fixture()
        self.output = mock.patch("sys.stdout", new_callable=io.StringIO)
        self.output.start()
        self.addCleanup(self.output.stop)

    def release_fixture(self, version=None, extra_files=None):
        version = version or self.VERSION
        prefix = f"catwalk3d-{version}-{self.TARGET}/"
        files = {
            "catwalk": b"#!/bin/sh\nexit 0\n",
            "LICENSE": b"Authored test fixture.\n",
            "release.json": json.dumps({"version": version, "target": self.TARGET, "binary": "catwalk"}).encode(),
        }
        if extra_files:
            files.update(extra_files)
        archive_data = io.BytesIO()
        with zipfile.ZipFile(archive_data, "w") as archive:
            for name, content in files.items():
                archive.writestr(prefix + name, content)
        data = archive_data.getvalue()
        manifest = {
            "schema": 1, "version": version, "target": self.TARGET, "binary": "catwalk",
            "archive": prefix[:-1] + ".zip", "sha256": hashlib.sha256(data).hexdigest(),
            "files": [{"path": prefix + name, "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}
                      for name, content in files.items()],
        }
        return manifest, data, files

    def downloads(self, manifest=None, archive=None):
        manifest = self.manifest if manifest is None else manifest
        archive = self.archive if archive is None else archive
        release_url = f"{self.REPOSITORY}/releases/download/{manifest['version']}/"
        responses = {
            release_url + manifest["archive"].removesuffix(".zip") + ".json": json.dumps(manifest).encode(),
            release_url + manifest["archive"]: archive,
        }
        return mock.patch.object(fetch, "download", side_effect=lambda url, limit: responses[url])

    def install(self):
        with self.downloads():
            fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)

    def test_fetches_upstream_manifest_and_archive_from_version_only_config(self):
        with self.downloads() as downloader:
            fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)
        base = f"{self.REPOSITORY}/releases/download/{self.VERSION}/catwalk3d-{self.VERSION}-{self.TARGET}"
        self.assertEqual(downloader.call_args_list, [
            mock.call(base + ".json", fetch.MAX_METADATA_BYTES), mock.call(base + ".zip", fetch.MAX_DOWNLOAD_BYTES)])
        self.assertEqual(json.loads((self.destination / ".manifest.json").read_text()), self.manifest)
        for name, content in self.files.items():
            self.assertEqual((self.destination / name).read_bytes(), content)
            self.assertEqual(stat.S_IMODE((self.destination / name).stat().st_mode), 0o755 if name == "catwalk" else 0o644)

    def test_check_and_repeated_fetch_use_cached_metadata_without_network(self):
        self.install()
        with mock.patch.object(fetch, "download") as downloader:
            fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY, check=True)
            fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)
        downloader.assert_not_called()

    def test_check_detects_modified_asset_without_network(self):
        self.install()
        (self.destination / "LICENSE").write_bytes(b"Changed license data.\n")
        with mock.patch.object(fetch, "download") as downloader:
            with self.assertRaisesRegex(ValueError, "Missing or unverified"):
                fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY, check=True)
        downloader.assert_not_called()

    def test_missing_cached_manifest_fails_check_without_network(self):
        self.install()
        (self.destination / ".manifest.json").unlink()
        with mock.patch.object(fetch, "download") as downloader:
            with self.assertRaisesRegex(ValueError, "release manifest"):
                fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY, check=True)
        downloader.assert_not_called()

    def test_version_update_downloads_new_metadata_and_replaces_old_assets(self):
        self.install()
        version = "2.2.0"
        manifest, archive, files = self.release_fixture(version)
        with self.downloads(manifest, archive):
            fetch.fetch_target(self.vendor, self.TARGET, version, self.REPOSITORY)
        self.assertEqual((self.destination / "release.json").read_bytes(), files["release.json"])
        fetch.check_target(self.destination, self.TARGET, version)

    def test_cli_check_accepts_target_list_configuration(self):
        self.install()
        configuration = {"version": self.VERSION, "repository": self.REPOSITORY,
                         "targets": [self.TARGET, "aarch64-unknown-linux-musl"]}
        (self.root / "config").mkdir()
        (self.root / "config/catwalk.json").write_text(json.dumps(configuration))
        with mock.patch.object(fetch, "__file__", str(self.root / "bin/fetch-test-catwalk")), \
                mock.patch("sys.argv", ["fetch-test-catwalk", "--check", "--target", self.TARGET]), \
                mock.patch.object(fetch, "download") as downloader:
            fetch.main()
        downloader.assert_not_called()

    def test_invalid_download_does_not_replace_previous_version(self):
        self.install()
        manifest, archive, _ = self.release_fixture("2.2.0")
        with self.downloads(manifest, archive + b"invalid"):
            with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                fetch.fetch_target(self.vendor, self.TARGET, "2.2.0", self.REPOSITORY)
        fetch.check_target(self.destination, self.TARGET, self.VERSION)

    def test_rejects_invalid_release_metadata_before_downloading_archive(self):
        bad_manifests = []
        for field, value in (("version", "2.0.0"), ("target", "wrong-target"), ("schema", 2),
                             ("archive", "../../catwalk.zip"), ("sha256", "invalid")):
            invalid = copy.deepcopy(self.manifest)
            invalid[field] = value
            bad_manifests.append((field, invalid))
        for name, value in (("traversal", f"catwalk3d-{self.VERSION}-{self.TARGET}/../catwalk"),
                            ("nested", f"catwalk3d-{self.VERSION}-{self.TARGET}/other/catwalk"),
                            ("outside", "catwalk")):
            invalid = copy.deepcopy(self.manifest)
            invalid["files"][0]["path"] = value
            bad_manifests.append((name, invalid))
        invalid = copy.deepcopy(self.manifest)
        invalid["files"].append(invalid["files"][0])
        bad_manifests.append(("duplicate", invalid))
        invalid = copy.deepcopy(self.manifest)
        invalid["files"][0]["size"] = fetch.MAX_EXTRACTED_BYTES + 1
        bad_manifests.append(("size limit", invalid))
        invalid = copy.deepcopy(self.manifest)
        invalid["files"] = invalid["files"][:1]
        bad_manifests.append(("missing notices and metadata", invalid))
        for name, invalid in bad_manifests:
            with self.subTest(name=name), mock.patch.object(fetch, "download", return_value=json.dumps(invalid).encode()) as downloader:
                with self.assertRaises(ValueError):
                    fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)
                self.assertEqual(downloader.call_count, 1)
                self.assertFalse(self.destination.exists())

    def test_archive_size_and_file_checksum_must_match_metadata(self):
        for field, value, message in (("size", 1, "Unexpected Catwalk release file"),
                                      ("sha256", "0" * 64, "Missing or unverified")):
            invalid = copy.deepcopy(self.manifest)
            invalid["files"][0][field] = value
            with self.subTest(field=field), self.downloads(invalid):
                with self.assertRaisesRegex(ValueError, message):
                    fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)
                self.assertFalse(self.destination.exists())

    def test_unlisted_archive_entry_is_rejected(self):
        _, archive, _ = self.release_fixture(extra_files={"../unexpected": b"unexpected"})
        manifest = copy.deepcopy(self.manifest)
        manifest["sha256"] = hashlib.sha256(archive).hexdigest()
        with self.downloads(manifest, archive):
            with self.assertRaisesRegex(ValueError, "Unexpected files"):
                fetch.fetch_target(self.vendor, self.TARGET, self.VERSION, self.REPOSITORY)
        self.assertFalse((self.vendor / "unexpected").exists())

    def test_cached_symlink_is_rejected(self):
        self.install()
        license_file = self.destination / "LICENSE"
        external = self.root / "external-license"
        license_file.rename(external)
        license_file.symlink_to(external)
        with self.assertRaisesRegex(ValueError, "Missing or unverified"):
            fetch.check_target(self.destination, self.TARGET, self.VERSION)

    def test_download_checks_byte_limit(self):
        with mock.patch.object(fetch.urllib.request, "urlopen", return_value=io.BytesIO(b"12345")):
            with self.assertRaisesRegex(ValueError, "download exceeds"):
                fetch.download("https://github.com/example/release.zip", 4)


if __name__ == "__main__":
    unittest.main()
