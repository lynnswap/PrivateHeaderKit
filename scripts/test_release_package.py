"""Package a pinned source revision and detect damaged release transfers."""
import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import package_release as packaging


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "tests")
        (self.source / "Package.swift").write_text("approved source")
        (self.source / "Package.resolved").write_text("locked dependencies")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.output = self.root / "release"

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True)

    def package(self):
        packaging.package(self.source, self.commit, "v1.2.3", "lynnswap/PrivateHeaderKit", self.output)

    def test_packages_approved_commit_instead_of_current_files(self):
        (self.source / "Package.swift").write_text("unapproved edit")
        self.package()
        packaging.verify(self.output, "v1.2.3")
        archive = self.output / packaging.asset_names("v1.2.3")[0]
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(archive.read_bytes()))) as source:
            self.assertEqual(source.extractfile("privateheaderkit-1.2.3/Package.swift").read(), b"approved source")
            self.assertIn("privateheaderkit-1.2.3/Package.resolved", source.getnames())
            self.assertFalse(any("/.git/" in name for name in source.getnames()))
        formula = (self.output / "privateheaderkit.rb").read_text()
        self.assertIn("/releases/download/v1.2.3/privateheaderkit-1.2.3.tar.gz", formula)
        self.assertIn(packaging.sha256(archive), formula)
        first = archive.read_bytes()
        self.package()
        self.assertEqual(archive.read_bytes(), first)

    def test_checksums_protect_both_source_and_formula(self):
        for name in packaging.asset_names("v1.2.3")[:2]:
            with self.subTest(name=name):
                self.package()
                (self.output / name).write_bytes(b"damaged transfer")
                with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                    packaging.verify(self.output, "v1.2.3")

    def test_publication_checksums_are_bound_to_verified_job(self):
        self.package()
        trusted = packaging.sha256(self.output / "SHA256SUMS.txt")
        packaging.verify(self.output, "v1.2.3", trusted)
        formula = self.output / "privateheaderkit.rb"
        formula.write_text("substituted formula")
        checksums = self.output / "SHA256SUMS.txt"
        lines = checksums.read_text().splitlines()
        lines[1] = f"{packaging.sha256(formula)}  privateheaderkit.rb"
        checksums.write_text("\n".join(lines) + "\n")
        with self.assertRaisesRegex(ValueError, "Transferred checksums"):
            packaging.verify(self.output, "v1.2.3", trusted)

    def test_version_classification(self):
        script = Path(__file__).with_name("release-version-is-prerelease.sh")
        for tag, value in (("v1.2.3", "false"), ("v1.2.3-rc.1", "true")):
            self.assertEqual(subprocess.check_output([str(script), tag], text=True).strip(), value)
        self.assertNotEqual(subprocess.run([str(script), "v1.2"], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
