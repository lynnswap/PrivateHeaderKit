#!/usr/bin/env python3
"""Run the installed release binaries against a small, local Objective-C fixture."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid


FIXTURE = """#import <Foundation/Foundation.h>
@interface PHKReleaseSmoke : NSObject
@property(nonatomic) NSInteger value;
@end
@implementation PHKReleaseSmoke
@end
int PHKReleaseSmokeValue(void) { return 42; }
"""

PLATFORMS = (
    ("macOS", "macosx", "arm64-apple-macosx14.0", "privateheaderkit-raw-helper"),
    ("iOS", "iphonesimulator", "arm64-apple-ios17.0-simulator", "privateheaderkit-sim-helper"),
    ("watchOS", "watchsimulator", "arm64-apple-watchos10.0-simulator", "privateheaderkit-watch-sim-helper"),
)


def run(arguments):
    return subprocess.run(list(map(str, arguments)), check=True, text=True,
                          stdout=subprocess.PIPE, timeout=300).stdout


def select_runtime(runtimes, platform):
    family = "iPhone" if platform == "iOS" else "Apple Watch"
    candidates = []
    for runtime in runtimes:
        if runtime["isAvailable"] and runtime["platform"] == platform:
            devices = [device for device in runtime["supportedDeviceTypes"]
                       if device["productFamily"] == family]
            if devices:
                candidates.append((runtime, devices[0]["identifier"]))
    if not candidates:
        raise RuntimeError(f"Install an available {platform} Simulator runtime to test the release helper.")
    return max(candidates, key=lambda pair: tuple(map(int, pair[0]["version"].split("."))))


def run_simulator_helper(platform, arguments):
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
    runtime, device_type = select_runtime(runtimes, platform)
    device = run(["xcrun", "simctl", "create", f"PHK Release Smoke {uuid.uuid4()}",
                  device_type, runtime["bundlePath"]]).strip()
    failure = None
    try:
        run(["xcrun", "simctl", "bootstatus", device, "-b"])
        run(["xcrun", "simctl", "spawn", device, *arguments])
    except BaseException as error:
        failure = error
        raise
    finally:
        try:
            run(["xcrun", "simctl", "delete", device])
        except Exception as cleanup_error:
            message = f"Failed to delete smoke-test simulator {device}: {cleanup_error}"
            if failure is not None:
                message = f"{failure}; {message}"
            raise RuntimeError(message) from cleanup_error


def smoke_cli_generation(command, fixture, directory):
    system_root = directory / "SystemRoot"
    library = system_root / "usr/lib/libReleaseSmoke.dylib"
    library.parent.mkdir(parents=True)
    shutil.copyfile(fixture, library)
    metadata = system_root / "System/Library/CoreServices/RestoreVersion.plist"
    metadata.parent.mkdir(parents=True)
    metadata.write_bytes(plistlib.dumps({"IsSeed": False}))
    output = directory / "generated"
    run([command, "--platform", "macOS", "--version", "15.0", "--build", "fixture",
         "--system-root", system_root, "--out", output, "--target", library.name, "--fresh"])
    headers = output / "generated-headers"
    if not any("@interface PHKReleaseSmoke" in path.read_text()
               for path in headers.rglob("PHKReleaseSmoke.h")):
        raise RuntimeError("The CLI did not generate the fixture through its prepared helper.")
    result = run([command, "search", "PHKReleaseSmokeValue", "--in", headers])
    if "PHKReleaseSmokeValue" not in result:
        raise RuntimeError("The CLI could not search its generated fixture symbols.")


def smoke(cohort, platforms=PLATFORMS):
    cohort = Path(cohort).resolve()
    command = cohort / "privateheaderkit"
    run([command, "--help"])
    with tempfile.TemporaryDirectory(prefix="privateheaderkit-smoke-") as temporary:
        root = Path(temporary)
        source = root / "ReleaseSmoke.m"
        source.write_text(FIXTURE)
        for platform, sdk, triple, helper in platforms:
            print(f"Testing installed {platform} release binaries", flush=True)
            directory = root / platform
            directory.mkdir()
            fixture = directory / "libReleaseSmoke.dylib"
            sdk_path = run(["xcrun", "--sdk", sdk, "--show-sdk-path"]).strip()
            run(["xcrun", "--sdk", sdk, "clang", "-target", triple,
                 "-isysroot", sdk_path, "-dynamiclib", "-fobjc-arc",
                 "-framework", "Foundation", source, "-o", fixture])
            headers = directory / "headers"
            arguments = [cohort / helper, "-o", headers, fixture]
            if platform == "macOS":
                run(arguments)
            else:
                run_simulator_helper(platform, arguments)
            header = (headers / "PHKReleaseSmoke.h").read_text()
            if "@interface PHKReleaseSmoke" not in header:
                raise RuntimeError(f"{helper} did not generate the fixture's Objective-C interface.")
            result = run([command, "search", "PHKReleaseSmokeValue", "--in", headers])
            if "PHKReleaseSmokeValue" not in result:
                raise RuntimeError(f"The installed CLI could not find symbols generated by {helper}.")
            if platform == "macOS":
                smoke_cli_generation(command, fixture, directory)
    print("Installed CLI and all requested helpers passed the release smoke test.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cohort-dir", required=True, type=Path)
    parser.add_argument("--platform", choices=[platform[0] for platform in PLATFORMS],
                        action="append", help="Test only these platforms (default: all).")
    arguments = parser.parse_args()
    platforms = [platform for platform in PLATFORMS
                 if arguments.platform is None or platform[0] in arguments.platform]
    try:
        smoke(arguments.cohort_dir, platforms=platforms)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
