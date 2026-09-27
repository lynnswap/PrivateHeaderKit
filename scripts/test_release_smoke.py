"""Release smoke orchestration tests with no SDK or Simulator dependencies."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import smoke_release_binaries as smoke


def runtime(platform, version="26.5", available=True):
    return dict(platform=platform, version=version, isAvailable=available,
                bundlePath=f"/runtimes/{platform}-{version}.simruntime",
                supportedDeviceTypes=[dict(identifier=f"{platform}-device",
                    productFamily="iPhone" if platform == "iOS" else "Apple Watch")])


class ReleaseSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.cohort = Path(self.temporary.name).resolve() / "installed-cohort"
        self.cohort.mkdir()
        self.calls = []
        self.failures = set()
        self.invalid_header = False
        self.missing_symbol = False
        self.patcher = patch.object(smoke, "run", side_effect=self.run_command)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def run_command(self, arguments):
        args = list(map(str, arguments))
        self.calls.append(args)
        if len(args) > 2 and args[:2] == ["xcrun", "simctl"]:
            operation = args[2]
            if operation in self.failures:
                raise subprocess.CalledProcessError(1, args)
            if operation == "list":
                return json.dumps({"runtimes": [runtime("iOS"), runtime("watchOS")]})
            if operation == "create":
                return "owned-device\n"
            if operation == "spawn":
                self.dump(args[4:])
        elif "--show-sdk-path" in args:
            return "/sdk\n"
        elif "search" in args:
            return "" if self.missing_symbol else "export PHKReleaseSmokeValue\n"
        elif args[0].endswith("privateheaderkit-raw-helper"):
            self.dump(args)
        return ""

    def dump(self, args):
        headers = Path(args[args.index("-o") + 1])
        headers.mkdir()
        (headers / "PHKReleaseSmoke.h").write_text(
            "" if self.invalid_header else "@interface PHKReleaseSmoke : NSObject\n@end\n")

    def test_runs_installed_helpers_and_searches_their_output(self):
        smoke.smoke(self.cohort)
        host_calls = [args for args in self.calls if args[0].startswith(str(self.cohort))]
        self.assertIn(str(self.cohort / "privateheaderkit-raw-helper"), [args[0] for args in host_calls])
        searches = [args for args in host_calls if "search" in args]
        self.assertEqual(len(searches), 3)
        spawns = [args for args in self.calls if args[:3] == ["xcrun", "simctl", "spawn"]]
        self.assertEqual([args[4] for args in spawns], [
            str(self.cohort / "privateheaderkit-sim-helper"),
            str(self.cohort / "privateheaderkit-watch-sim-helper"),
        ])
        deletes = [args for args in self.calls if args[:3] == ["xcrun", "simctl", "delete"]]
        self.assertEqual(deletes, [["xcrun", "simctl", "delete", "owned-device"]] * 2)

    def test_selects_available_runtime_for_the_requested_platform(self):
        selected, device = smoke.select_runtime([
            runtime("iOS", "26.5"), runtime("watchOS", "26.5"),
            runtime("iOS", "27.0", False), runtime("iOS", "18.0"),
        ], "iOS")
        self.assertEqual(selected["version"], "26.5")
        self.assertEqual(device, "iOS-device")
        with self.assertRaisesRegex(RuntimeError, "watchOS Simulator runtime"):
            smoke.select_runtime([runtime("iOS")], "watchOS")

    def test_failed_boot_or_helper_still_deletes_only_its_device(self):
        for operation in ("bootstatus", "spawn"):
            with self.subTest(operation=operation):
                self.calls.clear()
                self.failures = {operation}
                with self.assertRaises(subprocess.CalledProcessError):
                    smoke.run_simulator_helper("watchOS", [self.cohort / "helper"])
                self.assertEqual(self.calls[-1], ["xcrun", "simctl", "delete", "owned-device"])

    def test_reports_original_failure_and_cleanup_failure(self):
        self.failures = {"spawn", "delete"}
        with self.assertRaisesRegex(RuntimeError, "spawn.*Failed to delete.*delete"):
            smoke.run_simulator_helper("iOS", [self.cohort / "helper"])

    def test_bad_generated_output_fails_the_smoke_test(self):
        self.invalid_header = True
        with self.assertRaisesRegex(RuntimeError, "did not generate"):
            smoke.smoke(self.cohort, platforms=smoke.PLATFORMS[:1])
        self.invalid_header = False
        self.missing_symbol = True
        with self.assertRaisesRegex(RuntimeError, "could not find symbols"):
            smoke.smoke(self.cohort, platforms=smoke.PLATFORMS[:1])


if __name__ == "__main__":
    unittest.main()
