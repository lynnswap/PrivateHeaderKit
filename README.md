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

For iOS, `generate` resolves an available iOS simulator runtime from `--version`/`--build`, selects and boots a simulator device, and uses the internal simulator helper. `--system-root` is optional for iOS; when supplied, it is used as the runtime root instead of silently replacing it with the resolved runtime path. `--device <name-or-udid>` and `--sim-helper <path>` are optional automation flags.

`--target` is a comma-separated target query, not a stable target ID list. `--resume` is an explicit non-interactive resume request. The old `<version>` positional style is not part of the new public surface.

## Output Layout Contract

Default output is planned under:

```text
~/PrivateHeaderKit/
  iOS27.0(24A5355q)/
  .state/
    iOS27.0(24A5355q)/
      manifest.json
      runs/
```

For custom output, `--out` and `PH_OUT_DIR` are treated as an output base directory. Generated headers live under `<output-base>/<source-label>/`; state lives under `<output-base>/.state/<source-label>/`.

## Notes

- Requires Xcode command line tools (`xcrun`, `xcodebuild`) for Apple platform discovery and simulator execution.
- State, logs, and staging data are kept outside the generated header tree.
- The rewrite prioritizes resume-safe execution, explicit source identity, and a single public command over compatibility with the previous CLI.

## Testing

`swift test` is expected to be deterministic. Regular tests should use fixed fixture trees, injected environments, and stub command runners only.

Do not add regular tests that depend on the host dyld shared cache, installed system apps, simulator availability, runtime boot state, wall-clock time, generated `swiftc` binaries, network access, or stress loops. If an integration smoke test needs one of those dependencies, guard it behind an explicit opt-in such as `PHK_RUN_INTEGRATION_TESTS=1` and keep it out of the default acceptance path.

## License

- MIT for this workspace: see `LICENSE`.
