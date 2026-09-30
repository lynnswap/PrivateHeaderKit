# Contributing

PrivateHeaderKit uses Swift 6.3 as its baseline. Source builds require Xcode with `xcrun`, the iOS Simulator SDK, and the watchOS
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

CI uses the macOS 27 [`xcode-27` runner](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
with Xcode 27.1 to check macOS, iOS Simulator, and watchOS Simulator in parallel.
The macOS job runs `swift test --build-system swiftbuild` in Release configuration;
Simulator jobs compile CoreTests and the helper with testable imports. CI then
transfers the same macOS executables to Apple Silicon runners for macOS 26 and
27 and runs the CLI, header generation, and symbol search without rebuilding.
The host smoke test also generates a fixture through the public CLI so helper
preparation and bundled Swift runtime libraries are exercised.
`Package Checks` requires both the platform jobs and these execution checks to
succeed. macOS 14 remains the deployment target; versions before macOS 26 are
outside the supported distribution and verification range. The release workflow
separately builds the approved source archive through its Homebrew Formula on
macOS 26 with Xcode 26.6, matching the tap builder, and tests the installed bottle
before publication.

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
become prereleases. Use the Homebrew installation command at the start of stable
release notes once the tap is available:

```sh
brew install lynnswap/tap/privateheaderkit
```

The command creates or reuses a matching Draft Release, then dispatches the
`Release` workflow from the default branch. It prints the Draft and Actions URLs
without waiting for publication. Do not create or push the release tag locally.
After CI and Homebrew verification pass, review the candidate's version, target
SHA, content digest, and checksums in the Actions summary. Approve the
`release-publish` Environment through **Review deployments → Approve and deploy**.
The protected job then publishes that candidate automatically.
Source artifacts are retained for 35 days so the publication approval wait does
not outlive them. Approve or reject the candidate within GitHub's approval limit.

The workflow packages the approved Git commit as a source archive, preserving
`Package.resolved` and the checked-in SwiftPM mirrors. It generates a Formula
with that archive's canonical versioned URL and SHA-256. The source archive needs
no `.git` directory to build. Publication tooling comes from the workflow
revision; package tests run against the approved source revision.

A separate Homebrew job seeds the unpublished archive into Homebrew's download
cache, builds the Formula, runs its functional test, creates a bottle, reinstalls
that bottle and tests it again. Every helper also generates headers and symbols
from a small Objective-C fixture, and the installed CLI searches the result.
Simulator smoke tests create and delete their own temporary devices; available
iOS and watchOS runtimes are required for those release checks.

After package and Homebrew checks succeed and publication is approved, the
workflow publishes exactly:

- `privateheaderkit-<version>.tar.gz` (source; the filename version omits `v`)
- `privateheaderkit.rb`
- `SHA256SUMS.txt`

The publication job downloads the packaging job's exact artifact ID and binds
the transferred assets to its checksums digest. It never runs the source or
Formula with publication credentials.
After the first source release, copy its Formula into a pull request in
`lynnswap/homebrew-tap`. Once that Formula is published, the tap's scheduled
Renovate job proposes later release URL/checksum updates using its own
`GITHUB_TOKEN`. Review the update PR and approve its workflows to start CI.
Successful bottle CI prepares a candidate for the `homebrew-publish` Environment;
approve the reviewed head and tested artifact to publish the bottles and merge
the Formula update. Formula installation steps and dependencies still need an
explicit update when their requirements change. See the
[tap maintenance guide](https://github.com/lynnswap/homebrew-tap#automated-maintenance)
for these approvals and [Homebrew packaging](Homebrew/README.md) for initial
setup, local verification, and the future `homebrew/core` path.

For local source builds, use `scripts/build-release.sh --version dev`. Use
`--platform macos`, `--platform ios-simulator`, or `--platform watchos-simulator`
for one platform and `--output-dir <directory>` to select the output location.
The caller owns installation; the script only builds and stages executables.

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

Publication uses only the repository's `GITHUB_TOKEN`. If GitHub rejects tag
creation, inspect the tag rules and the target's workflow-file differences from
the current default branch. GitHub requires Workflows write permission when
the target changes those files relative to that branch; `GITHUB_TOKEN` cannot
receive that permission. Publication remains stopped. Any different release
target requires a new content approval and verification run.

### One-time publication setup

In **Settings → Environments → release-publish**, require the maintainer as a
reviewer, allow only the `main` branch, and disable administrator bypass. Leave
**Prevent self-review** off when the maintainer initiating the run is also its
approver. No environment secrets or additional release token are required.
Keep repository workflow permissions read-only by default; the workflow grants
write access only to draft validation and the protected publishing job. Draft
validation requires push access because GitHub treats unpublished releases as
private information.

Dependabot proposes weekly action and Swift dependency updates. Review those PRs
and their CI results; they are not merged automatically. Workflow changes should
remain reviewed changes to the publication policy.
