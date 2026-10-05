# Contributing

PrivateHeaderKit uses Swift 6.3 as its baseline. Source builds require Xcode with
`xcrun`, the iOS Simulator SDK, the watchOS Simulator SDK, and the iPhoneOS SDK.

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
with Xcode 27.1 to check macOS, iOS Simulator, watchOS Simulator, and iPhoneOS in parallel.
The macOS job runs `swift test --build-system swiftbuild` in Release configuration;
Simulator and iPhoneOS jobs compile CoreTests and the corresponding helper with
testable imports. The iPhoneOS job is a compile check; it does not connect to a
physical device or vphone. CI then
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

## Native Process-Image Recovery Verification

The iPhoneOS device helper provides `__process-images --pid <pid>` and
`__recover-process-image --pid <pid> --image-address <decimal-address>
--expected-uuid <uuid> --output <file>`. Use a running, attachable process on an
SSH-connected iPhoneOS or vphone peer for an opt-in native check. The standard
release build signs only that helper with `task_for_pid-allow`; task-port access
can still fail under the peer's security policy, and the operation reports the
native Mach error.

Select the image from the returned inventory and pass its UUID with its address.
Recovery copies the matching active Mach-O slice into a thin analysis file,
replaces declared encrypted ranges with corresponding loaded bytes, and clears
their encryption identifiers. The installed executable is preserved. This is an
analysis artifact; its original code signature does not authenticate the changed
bytes.

Confirm the recovered UUID and architecture, the bytes outside the declared
encrypted ranges and encryption identifiers, and the existing raw helper's
output. Keep any real application names, identifiers, device paths, executable
UUIDs, generated declarations, and raw logs out of public test records and
fixtures. A nonencrypted fixture validates task access and recovery, but does not
establish decryption of a distribution application.

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

## iPhoneOS Compile Check

Compile the iPhoneOS helper and Core test surface without connecting to a device:

```bash
scripts/build-release.sh --version dev --platform iphoneos --test
```

This uses `arm64-apple-ios17.0` and the selected Xcode's iPhoneOS SDK. Staging
produces `privateheaderkit-device-helper` and its
`privateheaderkit-runtime-iphoneos` directory. The peer's bootstrap and code
signing policy must permit the helper to run. The build uses ad hoc signing;
it does not install a bootstrap or provision a physical device.

SSH generation tests use fixture filesystem metadata, an injected command
runner, and binary archive chunks. They do not need an SSH server or a connected
device. Test the public CLI against a configured SSH peer separately when
changing deployment or device execution.

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
After package CI passes, the workflow prepares the public source tag and assets
automatically while the Release remains a Draft. Review the approved content,
prepared assets, and pinned workflow code in the Actions summary, then approve
`release-publish` through **Review deployments → Approve and deploy**. This gates
only the job that receives the GitHub App private key and dispatches the tap
update. The tap's bottle CI/publication and the source Release's remaining
installation checks and publication then proceed automatically.

The workflow creates the approved tag while the release stays a Draft. Its public
tag archive lets the tap build before stable publication. When adopting tag
archives, use the prepared Formula artifact for the tap update before core
stable publication. The verified artifact and checksums are shown in the later
publication summary. For stable releases, a read-only job checks the matching
public Formula/source checksum and macOS 26 Apple Silicon bottle asset, installs
that published bottle, checks the CLI's version and runs the Formula test and all
macOS/iOS/watchOS helper smoke tests. The
publisher rechecks the tested Formula and bottle identities immediately before
making the core release public. Changes to those artifacts require rerunning
**Verify published tap installation** and its dependent jobs; unrelated tap
changes do not invalidate the verified delivery. Prereleases do not require stable tap delivery.

Source artifacts are retained for 35 days so the publication approval wait does
not outlive them. Approve or reject the candidate within GitHub's approval limit.

The workflow downloads the public tag archive and verifies its files, executable
modes and symlinks against the approved Git commit, including `Package.resolved`
and the checked-in SwiftPM mirrors. It preserves the downloaded archive bytes
and generates a Formula with the public tag URL and SHA-256. The archive needs
no `.git` directory to build. Publication tooling comes from the workflow
revision; package tests run against the approved source revision.

For stable releases, tap CI owns the Homebrew source build and bottle generation.
Core verification installs the published bottle without rebuilding it. Every
helper generates headers and symbols from a small Objective-C fixture, and the
installed CLI searches the result. Prereleases keep isolated local Formula/bottle
verification because they do not require stable tap delivery.
Simulator smoke tests create and delete their own temporary devices; available
iOS and watchOS runtimes are required for those release checks.

After package and Homebrew checks succeed and publication is approved, the
workflow publishes exactly:

- `privateheaderkit-<version>.tar.gz` (source; the filename version omits `v`)
- `privateheaderkit.rb`
- `install.sh` (Homebrew installation and standalone migration)
- `SHA256SUMS.txt`

The publication job downloads the packaging job's exact artifact ID and binds
the transferred assets to its checksums digest. It never runs the source or
Formula with publication credentials.
When adopting tag archives, copy `privateheaderkit.rb` from the prepared Actions
artifact into a reviewed `lynnswap/homebrew-tap` PR. Do this before core stable
publication; the previous release-asset URL cannot discover an unpublished
release. Once the tag-archive Formula is published, the tap's Renovate job can
propose later tag URL/checksum updates using its own `GITHUB_TOKEN`. Native update PRs start pinned read-only CI automatically. Successful bottle CI prepares
a candidate for automatic publication; the publisher revalidates the head and
exact tested artifact before publishing bottles and merging the Formula update. Changes to
installation, dependencies or tests still require an explicit recipe update.
See the [tap maintenance guide](https://github.com/lynnswap/homebrew-tap/blob/main/CONTRIBUTING.md)
and [Homebrew packaging](Homebrew/README.md) for setup and verification.

The tap checks for an unproposed stable source tag every 15 minutes, alongside its
daily/manual maintenance. Existing update PRs wait for review and approval rather
than repeatedly starting Renovate. The public tag lets tap CI start independently
of core publication.

For local source builds, use `scripts/build-release.sh --version dev`. Use
`--platform macos`, `--platform ios-simulator`, `--platform watchos-simulator`, or `--platform iphoneos`
for one platform and `--output-dir <directory>` to select the output location.
The caller owns installation; the script only builds and stages executables.

The automatic tag preparation job creates the tag at the tested SHA. The final
publisher depends on the approved tap-dispatch job and automatically publishes the same Draft, preserving its title, notes, and prerelease state. Existing tags
must resolve to that SHA, including annotated tags. Stable releases use GitHub's
latest-release selection; prereleases are not marked latest. Draft verification
requires push access. Draft validation, tag creation and publication run trusted
scripts from the workflow commit with `contents: write`; tests and builds receive
only read access.

Do not edit the Draft, modify its assets, move its tag, or publish it manually
while the workflow runs. Changed publication content stops the workflow;
unrelated release metadata does not. GitHub does not provide a transaction
covering tags, assets, and publication, so maintainers must serialize those
operations.

Stable releases dispatch the tap update immediately after `release-publish`
approval. If delivery is still pending, **Check stable tap delivery** succeeds with
a wait summary and the Release remains a Draft. Tap CI builds the bottle and
publication runs automatically after its exact tested candidate is verified.
Periodic tap discovery remains available for recovery; normal release updates
need no manual PR creation or CI dispatch.

**Resume prepared releases** checks every 15 minutes. Its short trusted job
validates the unchanged Draft, original tap-dispatch approval, successful
checks and immutable preparation receipt/assets against matching public tap
delivery. It reruns only **Check stable tap delivery** and its dependent jobs in
the original run. SDK checks and completed preparation jobs are reused. No runner
or write token remains allocated during the intervening approval/delivery wait.
To request an immediate check after tap publication:

```sh
gh workflow run resume-release.yml --repo lynnswap/PrivateHeaderKit --ref main
```

The preparation receipt is derived run/artifact metadata, not a separate source
of approved release content. Changing Draft notes, target, tag or prepared bytes
blocks resumption; real verification/API failures remain errors. Approval of prepared runs is preserved. The resumption job uses own-repository
Actions write permission to rerun that job, and Contents write because GitHub
requires push access to read unpublished Drafts. It never executes source or
Formula code with these credentials and uses no cross-repository token; the separate approved tap-dispatch job uses a scoped App token.

For exceptional recovery, inspect the failure and rerun only the affected job
and dependents. Runs without preparation receipts require inspected recovery.
Do not choose **Re-run all jobs** for a tap
availability wait. GitHub permits reruns within 30 days; expired artifacts require
a fresh preparation run.

If checks fail, the release stays a Draft; the public source tag may already
remain. A failed upload or publication can leave some assets; use GitHub's re-run controls after fixing
the failure. The publish job replaces the four expected assets, checks their
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
approver. Store the tap-dispatch App Client ID and private key as described below;
only the approved tap-dispatch job receives those credentials.
Keep repository workflow permissions read-only by default; the workflow grants
write access only to Draft validation, tested-tag preparation, approved tap
notification, the publisher, and the short trusted resumption job. Draft
validation requires push access because GitHub treats unpublished releases as
private information.

Dependabot proposes weekly action and Swift dependency updates. Review those PRs
and their CI results; they are not merged automatically. Workflow changes should
remain reviewed changes to the publication policy.

### Tap dispatch App setup

Register a private GitHub App with **Actions: read and write** and install it on
`lynnswap/homebrew-tap` only. In this repository's `release-publish` Environment,
set `TAP_DISPATCH_APP_CLIENT_ID` as a variable and `TAP_DISPATCH_APP_PRIVATE_KEY`
as a secret containing the App's PEM private key. No webhook or user OAuth flow
is required. Only the approved tap-dispatch job receives the key; it runs trusted
workflow code, verifies unchanged approved content, and issues a token scoped to
that tap and `Actions: write`. The token is revoked when the job ends.

The release packager reads `Homebrew/installer.json` from the approved source
commit, downloads the shared installer from that immutable homebrew-tap revision,
and verifies its SHA-256 before embedding it in `install.sh`. Update the pin
deliberately when adopting shared installer changes. The generated installer is
covered by the release checksums and downloads no additional migration code at
execution time.
