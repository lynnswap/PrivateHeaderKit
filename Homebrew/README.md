# Homebrew packaging

PrivateHeaderKit is packaged as a source-based Formula. Homebrew owns its
installation, upgrade, version selection, and removal. The public command and
three private helpers are installed together in the formula's `libexec`;
only `privateheaderkit` is linked into Homebrew's `bin`. Required Swift compatibility
libraries are collected with `swift-stdlib-tool` and installed in platform-specific
sibling directories. Each executable locates its libraries relative to itself,
so it can run without the build host's Xcode installation.

`privateheaderkit.rb.in` is the release formula template. `scripts/package_release.py`
packages an approved Git commit as a source archive and fills the template with
that release's version, source URL, and SHA-256. The archive includes
`Package.resolved` and the checked-in SwiftPM mirror configuration. Building it
does not require `.git`.

The source release workflow verifies the Formula against the unpublished source
archive by placing it in Homebrew's download cache. Homebrew verifies the archive
against the Formula's checksum. The workflow builds a bottle, reinstalls it,
runs the Formula's functional test, and exercises all three helpers with local
Objective-C fixtures before publishing the source release.

## Update the shared tap

[lynnswap/homebrew-tap](https://github.com/lynnswap/homebrew-tap) owns the shared
Formula and bottle workflows. Maintain those workflows in that repository.
After publishing the first source release, download its `privateheaderkit.rb`, verify it
against `SHA256SUMS.txt`, and submit it under the tap's `Formula/` directory in a
pull request.

The source formula works before a bottle is published, provided the build
requirements are installed. Enable the tap's scheduled Renovate and protected
bottle-publication workflows as described in its
[maintenance guide](https://github.com/lynnswap/homebrew-tap#automated-maintenance).
With those workflows enabled, Renovate proposes later source URL/checksum updates
using the tap's own `GITHUB_TOKEN`; formula installation requirements still need
an explicit update when they change.

Review each Formula PR and approve workflows requested by Renovate to start CI.
The test workflow creates bottles and the publication workflow prepares a
candidate from the successful CI run. Approve its reviewed PR head and tested
artifact in the `homebrew-publish` Environment. The protected job verifies and
publishes those local bottle files using `brew pr-upload`, updates the bottle
metadata, and merges the Formula change. No cross-repository token or persistent
credential is needed. The tap guide documents required Actions settings,
manual dispatch and recovery operations.

The tap builds on Apple Silicon macOS 26 with Xcode 26.6 and uses the normal
Homebrew bottle tag for that host. No older-OS tag substitution is performed.
The source release's Homebrew check uses the same builder environment.

Upstream CI owns CLI/helper execution tests on macOS 26 and 27. macOS 14 remains
the executable deployment target, but older macOS versions are outside the
supported distribution and verification range. A successful build alone does not
establish compatibility with an older host.

Do not install the draft release formula outside the release verification job:
its canonical download URL becomes available only after publication. Never
publish a local test formula or bottle as a stable release.

## Local verification

Run the package/release contract tests first:

```sh
scripts/test-release-scripts.sh
```

On an Apple Silicon Mac with Swift 6.3 or later and both Simulator SDKs, create
source assets from a committed revision using a version chosen for local testing:

```sh
python3 scripts/package_release.py create \
  --source-root . --commit "$(git rev-parse HEAD)" \
  --version v0.0.0-local --repo lynnswap/PrivateHeaderKit \
  --output-dir .build/homebrew-release
scripts/test-homebrew.sh .build/homebrew-release --simulators
```

This uses a temporary `privateheaderkit/verification` tap. It requires that no
Homebrew `privateheaderkit` installation already exists, and removes its own
installation and tap afterwards. On failure, generated bottle files are kept at
the path printed in the error log. It does not change an older standalone install
or generated data. `--simulators` creates and deletes temporary devices and
requires available iOS and watchOS runtimes; omit it for the host Formula test.

For ordinary development, build directly with `scripts/build-release.sh` as
described in [installation](../Docs/installation.md).

## Future homebrew/core submission

Keep the formula buildable from versioned source, retain the functional test,
and keep build requirements separate from per-command runtime requirements.
Homebrew can build from source where a matching bottle is unavailable and the
host can run the required Xcode.
Acceptance into `homebrew/core` still requires review against its current
platform, dependency, license, and maintenance requirements.
