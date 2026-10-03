"""Run source builds with stub SDK tools, including an archive without .git."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


TOOL = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "xcrun":
    if args[:2] == ["--find", "swiftc"]:
        print(Path(sys.argv[0]).parent / "swiftc")
    elif args[0] == "swift-stdlib-tool":
        sdk = args[args.index("--platform") + 1]
        if os.environ.get("PHK_TEST_FAIL_RUNTIME") == sdk:
            sys.exit(25)
        runtime = Path(args[args.index("--destination") + 1]) / "libswiftCompatibilitySpan.dylib"
        runtime.write_text(sdk + " runtime")
        runtime.chmod(0o755)
    elif args[0] == "install_name_tool":
        if not args[2].startswith("@loader_path/privateheaderkit-runtime-"):
            sys.exit("runtime path must resolve beside the installed executable")
    else:
        print("/sdk/" + args[args.index("--sdk") + 1])
elif name == "swift":
    triple = args[args.index("--triple") + 1] if "--triple" in args else "macos"
    output = Path.cwd() / ".build" / "stub" / triple
    if "--show-bin-path" in args:
        print(output)
    else:
        with open(os.environ["PHK_TEST_LOG"], "a") as log:
            log.write(json.dumps({"args": args, "triple": triple, "source": str(Path.cwd()),
                                 "version": os.environ.get("PRIVATEHEADERKIT_BUILD_VERSION")}) + "\\n")
        if os.environ.get("PHK_TEST_FAIL") == triple:
            sys.exit(23)
        output.mkdir(parents=True, exist_ok=True)
        if "--target" not in args:
            products = (["privateheaderkit", "privateheaderkit-raw-helper"] if args[0] == "test"
                        else [args[args.index("--product") + 1]])
            for product in products:
                (output / product).write_text(triple + " " + product)
elif name == "codesign":
    if not os.access(args[-1], os.X_OK):
        sys.exit("binary is not executable")
    if os.environ.get("PHK_TEST_FAIL_SIGN") == Path(args[-1]).name:
        sys.exit(24)
    if "--entitlements" in args:
        import plistlib
        profile = Path(args[args.index("--entitlements") + 1])
        entitlements = plistlib.loads(profile.read_bytes())
    else:
        entitlements = {}
    with open(os.environ["PHK_TEST_SIGN_LOG"], "a") as log:
        log.write(json.dumps({"name": Path(args[-1]).name, "entitlements": entitlements}) + "\\n")
else:
    sys.exit("unexpected tool: " + name)
'''


class ReleaseBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source with spaces"
        (self.source / "scripts").mkdir(parents=True)
        self.script = self.source / "scripts/build-release.sh"
        shutil.copy2(Path(__file__).with_name("build-release.sh"), self.script)
        shutil.copy2(Path(__file__).with_name("device-helper.entitlements"), self.source / "scripts/device-helper.entitlements")
        stubs = self.root / "stubs"
        stubs.mkdir()
        for name in ("swift", "xcrun", "codesign"):
            path = stubs / name
            path.write_text(TOOL)
            path.chmod(0o755)
        self.log = self.root / "builds.jsonl"
        self.sign_log = self.root / "signatures.jsonl"
        self.output = self.root / "products"
        self.environment = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}",
                                PHK_TEST_LOG=str(self.log), PHK_TEST_SIGN_LOG=str(self.sign_log))

    def build(self, *args, **env):
        return subprocess.run([str(self.script), "--version", "v1.2.3", "--output-dir",
                               str(self.output), *map(str, args)], cwd=self.root,
                              env=dict(self.environment, **env), capture_output=True, text=True)

    def test_source_archive_builds_all_five_executables_without_git(self):
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), [
            "privateheaderkit", "privateheaderkit-device-helper", "privateheaderkit-raw-helper",
            "privateheaderkit-runtime-iphoneos", "privateheaderkit-runtime-iphonesimulator", "privateheaderkit-runtime-macosx",
            "privateheaderkit-runtime-watchsimulator", "privateheaderkit-sim-helper",
            "privateheaderkit-watch-sim-helper",
        ])
        for sdk in ("macosx", "iphonesimulator", "watchsimulator", "iphoneos"):
            runtime = self.output / f"privateheaderkit-runtime-{sdk}/libswiftCompatibilitySpan.dylib"
            self.assertEqual(runtime.read_text(), sdk + " runtime")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 5)
        self.assertTrue(all(call["version"] == "v1.2.3" for call in calls))
        self.assertTrue(all("--force-resolved-versions" in call["args"] for call in calls))
        self.assertIn("watchos10.0-simulator", (self.output / "privateheaderkit-watch-sim-helper").read_text())
        signatures = [json.loads(line) for line in self.sign_log.read_text().splitlines()]
        privileged = [item for item in signatures if item["entitlements"]]
        self.assertEqual(privileged, [{"name": "privateheaderkit-device-helper",
                                      "entitlements": {"task_for_pid-allow": True}}])

    def test_device_helper_uses_iphoneos_sdk_and_shared_runtime_staging(self):
        result = self.build("--platform", "iphoneos", "--test")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(call["triple"] == "arm64-apple-ios17.0" for call in calls))
        self.assertIn("privateheaderkit-device-helper", calls[0]["args"])
        self.assertIn("PrivateHeaderKitCoreTests", calls[1]["args"])
        self.assertEqual((self.output / "privateheaderkit-runtime-iphoneos/libswiftCompatibilitySpan.dylib").read_text(), "iphoneos runtime")

    def test_relative_source_root_resolves_device_signing_profile_after_chdir(self):
        result = self.build("--source-root", self.source.name, "--platform", "iphoneos")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(calls[0]["source"], str(self.source.resolve()))
        signatures = [json.loads(line) for line in self.sign_log.read_text().splitlines()]
        helper = next(item for item in signatures if item["name"] == "privateheaderkit-device-helper")
        self.assertEqual(helper["entitlements"], {"task_for_pid-allow": True})

    def test_ci_can_build_a_separate_source_directory(self):
        other = self.root / "other"
        other.mkdir()
        result = self.build("--source-root", other, "--platform", "macos", "--test")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["source"], str(other.resolve()))
        self.assertEqual(calls[0]["args"][0], "test")
        self.assertIn("swiftbuild", calls[0]["args"])

    def test_build_failure_is_propagated(self):
        result = self.build("--platform", "ios-simulator", PHK_TEST_FAIL="arm64-apple-ios17.0-simulator")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(self.output.iterdir()))

    def test_simulator_test_targets_are_compiled_with_matching_sdk(self):
        result = self.build("--platform", "watchos-simulator", "--test")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertIn("PrivateHeaderKitCoreTests", calls[1]["args"])
        self.assertTrue(all("arm64-apple-watchos10.0-simulator" == call["triple"] for call in calls))

    def test_late_build_or_signing_failure_preserves_previous_outputs(self):
        self.output.mkdir()
        previous = {name: "previous " + name for name in (
            "privateheaderkit", "privateheaderkit-raw-helper", "privateheaderkit-sim-helper",
            "privateheaderkit-watch-sim-helper", "unrelated.txt",
        )}
        for name, contents in previous.items():
            (self.output / name).write_text(contents)
        for failure in (
            {"PHK_TEST_FAIL": "arm64-apple-watchos10.0-simulator"},
            {"PHK_TEST_FAIL_SIGN": "privateheaderkit-watch-sim-helper"},
            {"PHK_TEST_FAIL_RUNTIME": "watchsimulator"},
        ):
            with self.subTest(failure=failure):
                result = self.build(**failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual({path.name: path.read_text() for path in self.output.iterdir()}, previous)

    def test_successful_platform_build_replaces_only_its_products(self):
        self.output.mkdir()
        (self.output / "privateheaderkit").write_text("previous command")
        (self.output / "privateheaderkit-watch-sim-helper").write_text("previous watch helper")
        runtime = self.output / "privateheaderkit-runtime-macosx/libswiftCompatibilitySpan.dylib"
        runtime.parent.mkdir()
        runtime.write_text("previous runtime")
        result = self.build("--platform", "macos")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / "privateheaderkit").read_text(), "macos privateheaderkit")
        self.assertEqual((self.output / "privateheaderkit-watch-sim-helper").read_text(), "previous watch helper")
        self.assertEqual(runtime.read_text(), "macosx runtime")
        self.assertTrue(os.access(self.output / "privateheaderkit", os.X_OK))
        self.assertFalse(list(self.output.glob(".privateheaderkit.*")))


if __name__ == "__main__":
    unittest.main()
