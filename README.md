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

```bash
swift run -c release privateheaderkit install
```

By default, this installs the single user-facing `privateheaderkit` binary to `~/.local/bin`.
Raw dumping also installs internal helpers to `~/.local/libexec/privateheaderkit/`.

If `~/.local/bin` is not in your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

To change the destination:

```bash
swift run -c release privateheaderkit install --prefix "$HOME/.local"
# or
swift run -c release privateheaderkit install --bindir "$HOME/bin"
```

If you prefer running the built binary directly:

```bash
swift build -c release --product privateheaderkit
"$(swift build -c release --show-bin-path)/privateheaderkit" install --bindir "$HOME/bin"
```

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
