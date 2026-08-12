# Contributing

PrivateHeaderKit uses Swift 6.3 as its baseline. Source builds and release
cohorts require Xcode with `xcrun` and an installed iOS Simulator SDK.

## Tests

Run the full Swift test suite:

```bash
swift test
```

Run the release-script contract tests when changing installation or release
packaging:

```bash
scripts/test-release-scripts.sh
```

Regular tests must be deterministic. Use fixture trees, injected environments,
and stub command runners. Do not make the default suite depend on the host dyld
shared cache, installed applications, simulator availability or boot state,
wall-clock timing, generated `swiftc` binaries, network access, or stress
loops. Gate a necessary integration smoke test behind an explicit opt-in such
as `PHK_RUN_INTEGRATION_TESTS=1`.

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

## Releases

Maintainers prepare releases with the `Prepare Draft Release` GitHub Actions
workflow. Dispatch it from the current default branch with:

- a version tag such as `v1.2.3`
- the full commit SHA of the current default-branch HEAD

The workflow builds and verifies the cohort, then creates or repairs a draft
GitHub Release containing exactly:

- `install.sh`
- `SHA256SUMS.txt`
- `privateheaderkit-darwin-arm64.tar.gz`

Review the draft metadata, release notes, and assets before publishing it
manually. Publishing and tag creation are not performed by the local build or
package scripts.
