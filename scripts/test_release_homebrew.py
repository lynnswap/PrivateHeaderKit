"""Verify that Homebrew test failures clean only the test's own installation."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


BREW = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
root = Path(os.environ["PHK_BREW_FIXTURE"])
args = sys.argv[1:]
if args[0] == "uninstall" and os.environ.get("HOMEBREW_NO_AUTOREMOVE") != "1":
    sys.exit("uninstall must not autoremove unrelated dependencies")
with (root / "calls").open("a") as calls:
    calls.write(json.dumps(args) + "\\n")
if args[0] == "list":
    sys.exit(0 if (root / "installed").exists() else 1)
elif args[0] == "tap-new":
    (root / "tap/Formula").mkdir(parents=True)
elif args[0] == "--repository":
    print(root / "tap")
elif args[0] == "--cache":
    print(root / "cache/source.tar.gz")
elif args[0] == "trust":
    (root / "trusted").touch()
elif args[0] == "install":
    (root / "installed").touch()
    sys.exit(23)
elif args[0] == "uninstall":
    (root / "installed").unlink()
elif args[0] == "untap":
    if not (root / "trusted").exists():
        sys.exit("cannot inspect an untrusted tap")
    (root / "tap-removed").touch()
elif args[0] == "untrust":
    (root / "trusted").unlink()
else:
    sys.exit("unexpected brew invocation: " + str(args))
'''


class HomebrewVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "brew").write_text(BREW)
        (self.root / "brew").chmod(0o755)
        self.release = self.root / "release"
        self.release.mkdir()
        (self.release / "privateheaderkit.rb").write_text("formula fixture")
        (self.release / "privateheaderkit-1.2.3.tar.gz").write_bytes(b"approved source")
        (self.release / "privateheaderkit-1.0.0.tar.gz").write_bytes(b"retired source")
        (self.release / "SHA256SUMS.txt").write_text("digest  privateheaderkit-1.2.3.tar.gz\n")
        self.environment = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}",
                                PHK_BREW_FIXTURE=str(self.root), TMPDIR=str(self.root))

    def verify(self):
        script = Path(__file__).with_name("test-homebrew.sh")
        return subprocess.run([str(script), str(self.release)], env=self.environment,
                              text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]

    def test_existing_installation_is_left_untouched(self):
        (self.root / "installed").write_text("user installation")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([call[0] for call in self.calls()], ["list"])
        self.assertEqual((self.root / "installed").read_text(), "user installation")

    def test_build_failure_keeps_exit_status_and_removes_owned_installation_and_trust(self):
        result = self.verify()
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertFalse((self.root / "installed").exists())
        self.assertFalse((self.root / "trusted").exists())
        self.assertTrue((self.root / "tap-removed").exists())
        self.assertEqual((self.root / "cache/source.tar.gz").read_bytes(), b"approved source")
        self.assertIn(["uninstall", "--force", "privateheaderkit/verification/privateheaderkit"], self.calls())


if __name__ == "__main__":
    unittest.main()
