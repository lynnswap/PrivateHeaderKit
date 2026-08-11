# PrivateHeaderKit

[Japanese](README.ja.md)

Generate private framework headers for iOS and macOS.

- iOS: dump from simulator runtimes and dyld shared caches.
- macOS: dump from host `/System/Library/{Frameworks,PrivateFrameworks}`.

## Rewrite Status

PrivateHeaderKit is being rewritten around a single user-facing command:

```bash
privateheaderkit
```

The old `privateheaderkit-dump`, `headerdump`, and `headerdump-sim` names are no longer installed or documented as user-facing commands. Low-level raw dumping is handled by internal helpers.

## Installation

On an Apple Silicon Mac, install the latest validated release cohort with the
version-baked installer:

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
sh install.sh
```

The installer downloads the matching archive and `SHA256SUMS.txt`, verifies the
archive before extraction, validates all three binaries, and only then switches
the active cohort. By default, the stable user-facing command is
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
  current -> versions/<version+content-sha256>
  versions/<version+content-sha256>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    release.json
```

Only `privateheaderkit` is public. The raw-dump helpers always come from the
same validated cohort. To update, download and run the latest `install.sh`
again, or update the source checkout and rerun `swift run -c release
privateheaderkit-install`. A failed build, download, validation, or staging step
does not change the active `current` pointer. Untagged source checkouts use a
commit-qualified `0.0.0-dev.<short-commit>` version namespace.

## Command Surface

```bash
privateheaderkit
privateheaderkit --help
```

Running `privateheaderkit` without arguments starts the interactive generation flow and writes to `~/PrivateHeaderKit`. For automation and CI, pass the generation options directly:

```bash
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --device "iPhone 17" --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
```

For iOS, `generate` resolves an available iOS simulator runtime from `--version`/`--build`, selects and boots a simulator device, and uses the internal simulator helper. If multiple installed runtimes have the requested version, `--build` is required; runtime resolution never depends on `simctl` output order. `--system-root` is optional for iOS; when supplied, it is used as the runtime root instead of silently replacing it with the resolved runtime path. The loaded dyld shared cache is used only when that root identifies the selected runtime (or `/` for macOS); a different custom root is scanned as a filesystem-only source, so cache-only targets are not advertised. `--device <name-or-udid>` and `--sim-helper <path>` are optional automation flags.

`--target` is a comma-separated target query, not a stable target ID list. `--resume` is an explicit non-interactive resume request. The old `<version>` positional style is not part of the new public surface.

## Output Layout Contract

Default output is planned under:

```text
~/PrivateHeaderKit/
  ios-v1-27.0-b1-24~415355~71/
  .state/
    ios-v1-27.0-b1-24~415355~71/
      manifest.json
      runs/
```

For custom output, `--out` selects the output base directory. Generated headers
live under `<output-base>/<source-storage-id>/`;
state lives under `<output-base>/.state/<source-storage-id>/`. The storage ID
is versioned and owned by PrivateHeaderKit; consumers must not construct it
from the displayed source label.

## Notes

- Requires Xcode command line tools (`xcrun`, `xcodebuild`) for Apple platform discovery and simulator execution.
- State, logs, and staging data are kept outside the generated header tree.
- The rewrite prioritizes resume-safe execution, explicit source identity, and a single public command over compatibility with the previous CLI.

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
