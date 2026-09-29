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
After publishing a source release, download its `privateheaderkit.rb`, verify it
against `SHA256SUMS.txt`, and submit it under the tap's `Formula/` directory in a
pull request.

The source formula works before a bottle is published, provided the build
requirements are installed. The tap workflows follow `brew tap-new`: the test
workflow creates bottle artifacts for formula pull requests, and the manually
dispatched publish workflow uses `brew pr-pull` to publish them and merge the
reviewed revision. Repository Actions settings must allow that workflow to
write contents and merge pull requests. No cross-repository token is needed
for this manual release-to-tap update process.

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
