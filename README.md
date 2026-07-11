# PrivateHeaderKit

[Japanese](README.ja.md)

Generate private framework headers for iOS and macOS.

- iOS: dump from simulator runtimes and dyld shared caches.
- macOS: dump from host `/System/Library/{Frameworks,PrivateFrameworks}`.

## Command Model

PrivateHeaderKit exposes one user-facing command:

```bash
privateheaderkit
```

The old `privateheaderkit-dump`, `headerdump`, and `headerdump-sim` names are not
installed as user-facing commands. Low-level raw dumping is handled by internal
helpers that are installed and updated with the public command as one cohort.

## Installation

On an Apple Silicon Mac, install the latest validated release cohort with the
version-baked installer:

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
sh install.sh
```

Each release has exactly three downloadable assets:

- `install.sh`
- `SHA256SUMS.txt`
- `privateheaderkit-darwin-arm64.tar.gz`

The version-baked installer downloads the matching archive and checksum file,
verifies the archive checksum and exact archive contents, then validates
`release.json` and all three executables for SHA-256, architecture, platform,
executable permissions, and code signature. Only after the complete cohort has
passed validation does it publish the immutable cohort and switch the active
`current` link. By default, the stable user-facing command is
`~/.local/bin/privateheaderkit`.

If `~/.local/bin` is not in your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

To choose another prefix or command directory:

```bash
sh install.sh --prefix "$HOME/.local"
# or: this uses $HOME as the prefix and $HOME/bin for the stable command
sh install.sh --bindir "$HOME/bin"
```

To build and install all artifacts from a checkout instead:

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

Release and source installs use the same immutable layout:

```text
~/.local/bin/privateheaderkit
  -> ../libexec/privateheaderkit/current/privateheaderkit
~/.local/libexec/privateheaderkit/
  current -> versions/<version>+<cohort-sha256>
  versions/<version>+<cohort-sha256>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    release.json
```

Only `privateheaderkit` is public. Its two helpers are always resolved through
the same validated cohort. To update, download and run the latest `install.sh`
again, or update the source checkout and rerun `swift run -c release
privateheaderkit-install`. A failed build, download, validation, staging, or
activation step restores or leaves active the previous validated cohort.
Untagged source checkouts use a commit-qualified
`0.0.0-dev.<short-commit>` version namespace.

An older direct install containing the three executable files is migrated under
the installer lock. If that migration is interrupted, the next install recovers
it from the recorded migration intent. A partial or ambiguous legacy layout is
rejected, and recovery refuses to guess if its files changed after the intent
was recorded.

Maintainers prepare a release with the `Prepare Draft Release` workflow. It must
be dispatched with a version and the full SHA of the current default-branch
HEAD. The workflow creates or repairs a draft GitHub Release with exactly the
three assets listed above. Publishing remains a manual step after the draft and
release notes have been reviewed.

## Generation

```bash
privateheaderkit
privateheaderkit --help
```

Running `privateheaderkit` without arguments starts the interactive generation
wizard; its default output base is `~/PrivateHeaderKit`. The wizard asks for an
explicit Continue or Restart decision when compatible unfinished state exists,
and asks for confirmation before migrating legacy state or output. For
automation and CI, pass generation options directly:

```bash
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --device "iPhone 17" --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit" --fresh
privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
```

For iOS generation, `privateheaderkit` resolves an available simulator runtime
from `--version` and `--build`, selects and boots a simulator device, and uses
the internal simulator helper. `--system-root` is optional for iOS; when
supplied, it is used as the runtime root instead of being replaced by the
resolved runtime path. `--device <name-or-udid>` and `--sim-helper <path>` are
optional automation flags.

`--target` is a comma-separated target query, not a stable target ID list.
`--resume` and `--fresh` are mutually exclusive:

- `--resume` continues the latest compatible plan and runs its unfinished or
  missing targets. A changed plan fingerprint or a smaller selected target set
  is rejected as incompatible.
- `--fresh` starts a new run for every selected target. It also permits the
  explicit migration of legacy JSON state and a legacy output directory.
- With neither flag, a new run starts when no prior state exists. Compatible
  state with no unfinished work may be reused, but unfinished state is rejected
  until the caller explicitly chooses `--resume` or `--fresh`.

`--fresh` does not delete the currently published header tree before work
starts. Every publication is built as a new immutable generation. A target that
finishes replaces only the files it owns; failed or interrupted targets retain
their last successfully published files. The old `<version>` positional style
is not part of the public surface.

## Output Layout Contract

The output base contains a stable source storage ID path, immutable generations,
and one SQLite state database per source:

```text
<output-base>/
  <source-storage-id> -> .privateheaderkit/<source-storage-id>/current
  .privateheaderkit/
    <source-storage-id>/
      current -> generations/<generation-id>
      generations/
        <generation-id>/
          .privateheaderkit-generation.json
          Frameworks/...
          PrivateFrameworks/...
      legacy-backups/...
  .state/
    <source-storage-id>/
      generation.sqlite
```

`--out` selects `<output-base>`. Consumers use
`<output-base>/<source-storage-id>/`, while publication metadata and immutable
generation directories remain under `.privateheaderkit`. The
`legacy-backups` directory is created only when a pre-rewrite output directory
is migrated. Generation state, target attempts, publication intent, and run
logs are stored in `generation.sqlite`. The storage ID is versioned and owned
by PrivateHeaderKit; consumers must not construct it from the displayed source
label.

## Legacy Output Migration

Old `.state/<source-storage-id>/manifest.json` and `runs/` data is not imported as
resumable state. When those paths exist without `generation.sqlite`, a run
without `--fresh` stops. An explicit fresh migration creates
`generation.sqlite` and leaves the old JSON paths in place.

An existing real `<output-base>/<source-storage-id>/` directory is not silently
adopted. With `--fresh`, PrivateHeaderKit inventories and copies its regular
files into the draft generation as opaque, unowned files. It then uses an
atomic directory/symlink swap to publish the managed stable path and retains
the original directory under
`.privateheaderkit/<source-storage-id>/legacy-backups/`. If the legacy tree cannot be
validated or the filesystem cannot perform the atomic swap, migration fails
without replacing the original output path.

## Notes

- iOS runtime discovery and simulator execution require Xcode with `xcrun`,
  `simctl`, and an installed iPhone Simulator SDK.
- Building or installing from source additionally requires the Swift 6.3
  toolchain.
- State, logs, and staging data are kept outside the published generated header
  tree.

## Testing

`swift test` is expected to be deterministic. Regular tests should use fixed fixture trees, injected environments, and stub command runners only.

Compile the platform-neutral Core target and its test surface for iOS without launching a simulator:

```bash
PHK_IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PHK_IOS_SIMULATOR_TRIPLE="$(uname -m)-apple-ios17.0-simulator"
PHK_IOS_BUILD_SCRATCH="$PWD/.build/privateheaderkit-ios-compile/$PHK_IOS_SIMULATOR_TRIPLE"
swift build --scratch-path "$PHK_IOS_BUILD_SCRATCH" --sdk "$PHK_IOS_SIMULATOR_SDK" --triple "$PHK_IOS_SIMULATOR_TRIPLE" --target PrivateHeaderKitCore
swift build --scratch-path "$PHK_IOS_BUILD_SCRATCH" --sdk "$PHK_IOS_SIMULATOR_SDK" --triple "$PHK_IOS_SIMULATOR_TRIPLE" --target PrivateHeaderKitCoreTests
```
Do not add regular tests that depend on the host dyld shared cache, installed system apps, simulator availability, runtime boot state, wall-clock time, generated `swiftc` binaries, network access, or stress loops. If an integration smoke test needs one of those dependencies, guard it behind an explicit opt-in such as `PHK_RUN_INTEGRATION_TESTS=1` and keep it out of the default acceptance path.

## License

- MIT for this workspace: see `LICENSE`.
