# Contributing

PrivateHeaderKit uses Swift 6.3 as its baseline. Source builds and release
cohorts require Xcode with `xcrun`, the iOS Simulator SDK, and the watchOS
Simulator SDK.

## Tests

Run the full Swift test suite:

```bash
swift test
```

Run the release-script contract tests when changing installation, packaging,
or release publication. The publication tests use an in-memory GitHub client:

```bash
scripts/test-release-scripts.sh
```

CI runs macOS tests and the iOS/watchOS compile checks in parallel. The
`Package Checks` job succeeds only when all three platform jobs succeed.
Simulator checks compile the targets described below without booting a device.

Regular tests must be deterministic. Use fixture trees, injected environments,
and stub command runners. Do not make the default suite depend on the host dyld
shared cache, installed applications, simulator availability or boot state,
wall-clock timing, generated `swiftc` binaries, network access, or stress
loops. Gate a necessary integration smoke test behind an explicit opt-in such
as `PHK_RUN_INTEGRATION_TESTS=1`.

## Optional Objective-C Bind Integration Test

Run file-backed dumps against an installed iOS 27.x Simulator runtime:

```bash
PHK_RUN_INTEGRATION_TESTS=1 \
PHK_OBJC_BIND_RUNTIME_ROOT="/path/to/iOS 27.1.simruntime/Contents/Resources/RuntimeRoot" \
swift test --filter ObjCChainedBindIntegrationTests
```

The test covers AdSupport, BrowserKit, SensorKit, and MetricKit without runtime
supplementation. It checks class roots and generated headers, including AdSupport's class methods,
and verifies that Objective-C metadata diagnostics are empty. A booted Simulator
is not required for this test.

## Optional Ghidra Integration Test

The default suite uses an injected command runner and does not require Ghidra.
To compile a small local ObjC++ fixture and exercise real C/C++/Objective-C
decompilation, missing/data/ambiguous symbol errors, and the temporary workspace:

```bash
PHK_RUN_INTEGRATION_TESTS=1 \
GHIDRA_HOME=/path/to/ghidra \
JAVA_HOME=/path/to/jdk/Contents/Home \
swift test --filter PrivateHeaderKitGhidraIntegrationTests
```

This opt-in test requires Xcode and a Ghidra installation with a working native
decompiler. It uses no external model service.

## iOS Compile Check

Compile the platform-neutral Core target and its test surface for iOS without
launching a simulator:

```bash
PHK_IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PHK_IOS_SIMULATOR_TRIPLE="$(uname -m)-apple-ios17.0-simulator"
PHK_IOS_BUILD_SCRATCH="$PWD/.build/privateheaderkit-ios-compile/$PHK_IOS_SIMULATOR_TRIPLE"
swift build \
  --scratch-path "$PHK_IOS_BUILD_SCRATCH" \
  --sdk "$PHK_IOS_SIMULATOR_SDK" \
  --triple "$PHK_IOS_SIMULATOR_TRIPLE" \
  --target PrivateHeaderKitCore
swift build \
  --scratch-path "$PHK_IOS_BUILD_SCRATCH" \
  --sdk "$PHK_IOS_SIMULATOR_SDK" \
  --triple "$PHK_IOS_SIMULATOR_TRIPLE" \
  --target PrivateHeaderKitCoreTests
```

## watchOS Compile Check

Compile the Core surface, its test surface, and the shared simulator-helper
product for watchOS without launching a simulator:

```bash
PHK_WATCHOS_SIMULATOR_SDK="$(xcrun --sdk watchsimulator --show-sdk-path)"
PHK_WATCHOS_SIMULATOR_TRIPLE="arm64-apple-watchos-simulator"
PHK_WATCHOS_BUILD_SCRATCH="$PWD/.build/privateheaderkit-watchos-compile/$PHK_WATCHOS_SIMULATOR_TRIPLE"
swift build \
  --scratch-path "$PHK_WATCHOS_BUILD_SCRATCH" \
  --sdk "$PHK_WATCHOS_SIMULATOR_SDK" \
  --triple "$PHK_WATCHOS_SIMULATOR_TRIPLE" \
  --target PrivateHeaderKitCore
swift build \
  --scratch-path "$PHK_WATCHOS_BUILD_SCRATCH" \
  --sdk "$PHK_WATCHOS_SIMULATOR_SDK" \
  --triple "$PHK_WATCHOS_SIMULATOR_TRIPLE" \
  --target PrivateHeaderKitCoreTests
swift build \
  --scratch-path "$PHK_WATCHOS_BUILD_SCRATCH" \
  --sdk "$PHK_WATCHOS_SIMULATOR_SDK" \
  --triple "$PHK_WATCHOS_SIMULATOR_TRIPLE" \
  --product privateheaderkit-sim-helper
```

The SwiftPM product keeps the name `privateheaderkit-sim-helper` for both
Simulator platforms. Release staging installs the watchOS build as
`privateheaderkit-watch-sim-helper` so each Mach-O platform remains explicit.

## Releases

Maintainers approve the version, title, release notes, full target commit SHA,
and automatic publication before starting a release. Save the approved notes
in a UTF-8 file, then run:

```bash
python3 scripts/release.py start v1.2.3 \
  --repo lynnswap/PrivateHeaderKit \
  --target <approved-full-commit-sha> \
  --notes-file /path/to/release-notes.md
```

Use `--title` to override the title, which defaults to the version. Stable tags
such as `v1.2.3` become stable releases; suffixed tags such as `v1.2.3-rc.1`
become prereleases. Keep the installation command at the start of stable release
notes:

```bash
curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh
```

The command creates or reuses a matching Draft Release with these notes, then
dispatches the `Release` workflow from the default branch. It prints the Draft
and Actions URLs without waiting for publication. Draft creation alone does not
start the workflow. Do not create or push the release tag locally.

The workflow runs CI against the approved SHA, including package tests and the
iOS/watchOS compile checks. It builds macOS, iOS Simulator, and watchOS Simulator
release binaries in parallel with the same version, target SHA, and Xcode
configuration. A macOS assembly job collects the binaries, restores executable
permissions, signs and validates them, then creates the complete `release.json`
and verifies the packaged cohort and installer. Only after validation and
assembly succeed does it attach and verify exactly:

- `install.sh`
- `SHA256SUMS.txt`
- `privateheaderkit-darwin-arm64.tar.gz`

For local builds, `scripts/build-release.sh --version <tag> --commit <sha>`
still builds and stages the complete cohort under `dist/arm64`. Use
`--platform macos`, `--platform ios-simulator`, or `--platform watchos-simulator`
to stage one platform under `dist/<platform>`. After collecting those three
directories, `--artifacts-root <directory>` assembles the cohort without
rebuilding. Each platform directory includes `build-info.txt` with its version
and commit; assembly requires those values to match the requested release.
`--dist-root` selects the output root in either mode.

The final job creates the tag at the tested SHA and automatically publishes the
same Draft, preserving its title, notes, and prerelease state. Existing tags
must resolve to that SHA, including annotated tags. Stable releases use GitHub's
latest-release selection; prereleases are not marked latest. Draft verification
requires push access, so both preparation and publication run trusted scripts
from the workflow commit with `contents: write`. Tests and builds receive only
read access.

Do not edit the Draft, modify its assets, move its tag, or publish it manually
while the workflow runs. Changed publication content stops the workflow;
unrelated release metadata does not. GitHub does not provide a transaction
covering tags, assets, and publication, so maintainers must serialize those
operations.

If checks fail, the release stays a Draft. A failed upload or publication can
leave some assets or the correct tag; use GitHub's re-run controls after fixing
the failure. The publish job replaces the three expected assets, checks their
uploaded digests, and resumes without moving an existing tag. Unexpected assets
require maintainer review and removal. Rerunning after successful publication
does not modify the published release. If dispatch fails or its response is
uncertain, inspect Actions before repeating the start command to avoid a second
run. Changed notes require a new start command matching the reviewed content.

The publish job uses `GITHUB_TOKEN` by default. If GitHub rejects tag creation
because the target needs Workflows permission, configure the optional
`RELEASE_TOKEN` Actions secret with **Contents: write** and **Workflows: write**
for this repository, then rerun the failed publish job. That credential is
available only to the publication step; repository tag rules still apply.
