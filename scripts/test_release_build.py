"""Exercise release staging with stub toolchains; no SDK or simulator is needed."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = '''#!/usr/bin/env python3
# platform: MACOS
import hashlib
import json
from pathlib import Path
import sys
args = {}
for flag in ("--artifact-dir", "--version", "--commit", "--output"):
    args[flag] = sys.argv[sys.argv.index(flag) + 1]
root = Path(args["--artifact-dir"])
files = sorted(path for path in root.iterdir() if path.name != "release.json")
manifest = {
    "version": args["--version"],
    "commit": args["--commit"],
    "artifacts": {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
}
Path(args["--output"]).write_text(json.dumps(manifest, sort_keys=True))
'''

TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "uname":
    print("arm64" if args == ["-m"] else "Darwin")
elif tool == "xcrun":
    print("/stub-sdk/" + args[args.index("--sdk") + 1])
elif tool == "swift":
    triple = args[args.index("--triple") + 1] if "--triple" in args else "macos"
    platform = "WATCHOSSIMULATOR" if "watchos" in triple else "IOSSIMULATOR" if "ios" in triple else "MACOS"
    output = Path.cwd() / ".build" / "stub" / triple
    if "--show-bin-path" in args:
        print(output)
    else:
        product = (args[args.index("--product") + 1] if "--product" in args else
                   args[args.index("--target") + 1] if "--target" in args else args[0])
        with open(os.environ["PHK_TEST_LOG"], "a") as log:
            log.write(json.dumps({"platform": platform, "product": product, "args": args,
                "source": str(Path.cwd()),
                "version": os.environ.get("PRIVATEHEADERKIT_BUILD_VERSION"),
                "commit": os.environ.get("PRIVATEHEADERKIT_BUILD_COMMIT")}) + "\\n")
        if os.environ.get("PHK_TEST_FAIL_PLATFORM") == platform:
            sys.exit(23)
        output.mkdir(parents=True, exist_ok=True)
        if args[0] == "test" and os.environ.get("PHK_TEST_FAIL_TESTS"):
            sys.exit(24)
        if "--target" in args:
            if os.environ.get("PHK_TEST_FAIL_TESTS"):
                sys.exit(24)
            sys.exit(0)
        if args[0] == "test":
            products = ["privateheaderkit", "privateheaderkit-install", "privateheaderkit-raw-helper"]
        else:
            products = [product]
        for product in products:
            path = output / product
            if product == "privateheaderkit-install":
                path.write_text(Path(os.environ["PHK_TEST_INSTALLER"]).read_text())
            else:
                path.write_text("# platform: " + platform + "\\n" + product + "\\n")
elif tool == "codesign":
    if not os.access(args[-1], os.X_OK):
        sys.exit("binary is not executable")
elif tool == "lipo":
    print("arm64")
elif tool == "vtool":
    binary = Path(args[-1]).read_text()
    platform = next(line.split(": ", 1)[1] for line in binary.splitlines() if line.startswith("# platform: "))
    print("platform " + platform)
else:
    sys.exit("unexpected tool: " + tool)
'''


class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        self.script = scripts / "build-release.sh"
        shutil.copy2(Path(__file__).with_name("build-release.sh"), self.script)
        self.git("init", "--quiet")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "user.name", "release-script-tests")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        stubs = self.root / "stubs"
        stubs.mkdir()
        for name in ("uname", "xcrun", "swift", "codesign", "lipo", "vtool"):
            path = stubs / name
            path.write_text(TOOL)
            path.chmod(0o755)
        installer = self.root / "installer"
        installer.write_text(INSTALLER)
        self.log = self.root / "builds.jsonl"
        self.environment = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}",
                                PHK_TEST_LOG=str(self.log), PHK_TEST_INSTALLER=str(installer))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args],
                              check=True, capture_output=True, text=True)

    def build(self, *args, success=True, commit=None, **environment):
        result = subprocess.run([str(self.script), "--version", "v1.2.3", "--commit",
                                 commit or self.commit, *map(str, args)], cwd=self.repo,
                                env=dict(self.environment, **environment),
                                capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def build_parts(self):
        parts = self.root / "parts"
        for platform in ("macos", "ios-simulator", "watchos-simulator"):
            self.build("--platform", platform, "--dist-root", parts)
        return parts

    @staticmethod
    def contents(root):
        return {str(path.relative_to(root)): path.read_bytes()
                for path in root.rglob("*") if path.is_file()}

    def test_platform_builds_assemble_like_local_build(self):
        parts = self.build_parts()
        builds = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([entry["platform"] for entry in builds],
                         ["MACOS"] * 3 + ["IOSSIMULATOR", "WATCHOSSIMULATOR"])
        for entry in builds:
            self.assertEqual((entry["version"], entry["commit"]), ("v1.2.3", self.commit))
        self.assertFalse(list(parts.rglob("release.json")))
        # Artifact downloads restore files without executable permissions.
        for path in parts.rglob("*"):
            if path.is_file():
                path.chmod(0o644)
        assembled = self.root / "assembled"
        self.build("--artifacts-root", parts, "--dist-root", assembled,
                   PHK_TEST_FAIL_PLATFORM="MACOS")
        self.assertEqual(len(self.log.read_text().splitlines()), 5, "assembly rebuilt binaries")
        cohort = assembled / "arm64" / "cohort"
        manifest = json.loads((cohort / "release.json").read_text())
        for name, digest in manifest["artifacts"].items():
            self.assertTrue(os.access(cohort / name, os.X_OK))
            self.assertEqual(digest, hashlib.sha256((cohort / name).read_bytes()).hexdigest())
        self.assertNotEqual(manifest["artifacts"]["privateheaderkit-sim-helper"],
                            manifest["artifacts"]["privateheaderkit-watch-sim-helper"])
        local = self.root / "local"
        self.build("--dist-root", local)
        self.assertEqual(self.contents(assembled), self.contents(local))
        self.build("--artifacts-root", parts, "--dist-root", assembled)
        self.assertEqual(self.contents(assembled), self.contents(local))

    def test_platform_tests_reuse_the_release_build(self):
        parts = self.root / "parts"
        for platform in ("macos", "ios-simulator", "watchos-simulator"):
            self.build("--platform", platform, "--test", "--dist-root", parts)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 5)
        host = calls[0]["args"]
        self.assertEqual(host[0], "test")
        self.assertEqual(host[host.index("--build-system") + 1], "swiftbuild")
        self.assertEqual(host[host.index("--sdk") + 1], "/stub-sdk/macosx")
        self.assertEqual(host[host.index("-c") + 1], "release")
        self.assertTrue((parts / "macos/cohort/privateheaderkit-raw-helper").is_file())
        for build, test in zip(calls[1::2], calls[2::2]):
            self.assertEqual(build["platform"], test["platform"])
            self.assertEqual(build["version"], test["version"])
            self.assertEqual(build["commit"], test["commit"])
            for call in (build, test):
                args = call["args"]
                self.assertEqual(args[args.index("-c") + 1], "release")
                self.assertIn("-enable-testing", args)
            if build["platform"] != "MACOS":
                for option in ("--scratch-path", "--sdk", "--triple"):
                    self.assertEqual(build["args"][build["args"].index(option) + 1],
                                     test["args"][test["args"].index(option) + 1])
                self.assertEqual(test["product"], "PrivateHeaderKitCoreTests")

    def test_failed_tests_do_not_stage_new_binaries(self):
        output = self.root / "parts"
        for platform in ("macos", "ios-simulator", "watchos-simulator"):
            with self.subTest(platform=platform):
                self.build("--platform", platform, "--dist-root", output)
                original = self.contents(output)
                result = self.build("--platform", platform, "--test", "--dist-root", output,
                                    success=False, PHK_TEST_FAIL_TESTS="1")
                self.assertEqual(result.returncode, 24)
                self.assertEqual(self.contents(output), original)

    def test_workflow_tooling_builds_an_older_source_checkout(self):
        source = self.root / "older-source"
        (source / "scripts").mkdir(parents=True)
        legacy_script = source / "scripts/build-release.sh"
        legacy_script.write_text("#!/bin/sh\necho 'Unknown argument: --test' >&2\nexit 1\n")
        legacy_script.chmod(0o755)
        for args in (("init", "--quiet"), ("add", "."),
                     ("-c", "user.name=release-script-tests", "-c", "user.email=tests@example.invalid",
                      "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "older source")):
            subprocess.run(["git", "-C", str(source), *args], check=True, capture_output=True)
        commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        self.assertNotEqual(commit, self.commit)
        output = self.root / "parts"
        for platform in ("macos", "ios-simulator", "watchos-simulator"):
            self.build("--source-root", source, "--test", "--platform", platform,
                       "--dist-root", output, commit=commit)
            self.assertEqual((output / platform / "build-info.txt").read_text(), f"v1.2.3 {commit}\n")
        for call in map(json.loads, self.log.read_text().splitlines()):
            self.assertEqual(call["source"], str(source.resolve()))
            self.assertEqual(call["commit"], commit)
        self.assertFalse((self.repo / ".build").exists())
        self.build("--artifacts-root", output, "--dist-root", self.root / "assembled", commit=commit)
        (source / "changed-source").write_text("uncommitted change")
        result = self.build("--source-root", source, "--test", "--platform", "macos",
                            "--dist-root", output, commit=commit, success=False)
        self.assertIn("Release source must be clean before building", result.stderr)

    def test_missing_helper_preserves_previous_cohort(self):
        parts = self.build_parts()
        output = self.root / "assembled"
        self.build("--artifacts-root", parts, "--dist-root", output)
        original = self.contents(output)
        (parts / "watchos-simulator/cohort/privateheaderkit-watch-sim-helper").unlink()
        self.build("--artifacts-root", parts, "--dist-root", output, success=False)
        self.assertEqual(self.contents(output), original)
        self.assertFalse(list(output.glob(".arm64.staging.*")))

    def test_wrong_platform_is_rejected_during_assembly(self):
        parts = self.build_parts()
        shutil.copyfile(parts / "ios-simulator/cohort/privateheaderkit-sim-helper",
                        parts / "watchos-simulator/cohort/privateheaderkit-watch-sim-helper")
        output = self.root / "assembled"
        result = self.build("--artifacts-root", parts, "--dist-root", output, success=False)
        self.assertIn("Expected WATCHOSSIMULATOR platform", result.stderr)
        self.assertFalse((output / "arm64").exists())

    def test_mixed_build_identity_preserves_previous_cohort(self):
        parts = self.build_parts()
        output = self.root / "assembled"
        self.build("--artifacts-root", parts, "--dist-root", output)
        original = self.contents(output)
        for platform in ("macos", "ios-simulator", "watchos-simulator"):
            identity = parts / platform / "build-info.txt"
            for version, commit in (("v9.9.9", self.commit), ("v1.2.3", "f" * 40)):
                with self.subTest(platform=platform, version=version, commit=commit):
                    identity.write_text(f"{version} {commit}\n")
                    result = self.build("--artifacts-root", parts, "--dist-root", output,
                                        success=False)
                    self.assertIn(f"Release build identity mismatch for {platform}", result.stderr)
                    self.assertEqual(self.contents(output), original)
            identity.write_text(f"v1.2.3 {self.commit}\n")

    def test_failed_build_preserves_previous_platform(self):
        output = self.root / "parts"
        self.build("--platform", "watchos-simulator", "--dist-root", output)
        original = self.contents(output)
        result = self.build("--platform", "watchos-simulator", "--dist-root", output,
                            success=False, PHK_TEST_FAIL_PLATFORM="WATCHOSSIMULATOR")
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.contents(output), original)

    def test_platform_output_inside_checkout_does_not_dirty_source(self):
        self.build("--platform", "macos")
        self.build("--platform", "ios-simulator")
        self.build("--platform", "watchos-simulator")
        self.build("--platform", "macos")
        (self.repo / "untracked-source").write_text("source changed")
        result = self.build("--platform", "macos", success=False)
        self.assertIn("Release source must be clean before building", result.stderr)


if __name__ == "__main__":
    unittest.main()
