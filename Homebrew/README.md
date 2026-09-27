# Homebrew packaging

PrivateHeaderKit is packaged as a source-based Formula. Homebrew owns its
installation, upgrade, version selection, and removal. The public command and
three private helpers are installed together in the formula's `libexec`;
only `privateheaderkit` is linked into Homebrew's `bin`.

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

## Prepare the shared tap

`tap/` contains the initial files for `lynnswap/homebrew-tap`. It is shared by
PrivateHeaderKit and any other tools added under `Formula/`; it is not a
PrivateHeaderKit-specific build system. These files are a bootstrap template,
not a second live copy of the tap. After creating the tap, maintain its workflows
in that repository.

After the first source release using this packaging has been published:

1. Copy the contents of `Homebrew/tap/`, including `.github`, into a new local
   `homebrew-tap` repository.
2. Create its `Formula` directory and download the published `privateheaderkit.rb`
   into that directory. Check `SHA256SUMS.txt` from the same release.
3. Publish the tap repository through the normal repository approval process.
4. Use a formula pull request to build and publish bottles with the shared CI.

The source formula works before a bottle is published, provided the build
requirements are installed. The tap workflows follow `brew tap-new`: the test
workflow creates bottle artifacts for formula pull requests, and the manually
dispatched publish workflow uses `brew pr-pull` to publish them and merge the
reviewed revision. Repository Actions settings must allow that workflow to
write contents and merge pull requests. No cross-repository token is needed
for this manual release-to-tap update process.

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
The tap may publish bottles for a subset of the package's supported systems;
Homebrew can build from source where a matching bottle is unavailable.
Acceptance into `homebrew/core` still requires review against its current
platform, dependency, license, and maintenance requirements.
