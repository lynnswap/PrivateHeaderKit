# PrivateHeaderKit

[日本語](README.ja.md)

Generate private framework headers for iOS and macOS.

- iOS: dump from simulator runtimes (dyld shared cache).
- macOS: dump from host `/System/Library/{Frameworks,PrivateFrameworks}`.

## Installation

```bash
swift run -c release privateheaderkit-install
```

By default, `privateheaderkit-install` installs the following binaries to `~/.local/bin`:

- `privateheaderkit-dump`
- `headerdump` (host)
- `headerdump-sim` (iOS Simulator)

If `~/.local/bin` is not in your `PATH`, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

To change the destination:

```bash
swift run -c release privateheaderkit-install --prefix "$HOME/.local"
# or
swift run -c release privateheaderkit-install --bindir "$HOME/bin"
```

If you prefer running the built binary directly:

```bash
swift build -c release --product privateheaderkit-install
"$(swift build -c release --show-bin-path)/privateheaderkit-install" --bindir "$HOME/bin"
```

## Usage

### 1) Dump headers

```
privateheaderkit-dump
```

### 2) Dump headers with args

```
privateheaderkit-dump 26.2
```

Default output directory is `~/PrivateHeaderKit/generated-headers/iOS/<version>`.
This dumps both `Frameworks` and `PrivateFrameworks`.
(Relative paths passed to `--out` / `PH_OUT_DIR` are resolved from the current directory. If you want the old output under this repo, run from the repo root and pass `--out generated-headers/iOS/<version>` or set `PH_OUT_DIR`.)

### 3) Dump specific targets (`--target`)

`--target` lets you select what to dump (repeatable, additive).  
If you don't pass `--target`, it's the same as `--target @frameworks`.

Examples:

```
# A single framework
privateheaderkit-dump 26.2 --target SafariShared

# A single SystemLibrary bundle
privateheaderkit-dump 26.2 --target PreferenceBundles/Foo.bundle

# A single usr/lib dylib
privateheaderkit-dump 26.2 --target /usr/lib/libobjc.A.dylib

# Presets
privateheaderkit-dump 26.2 --target @frameworks
privateheaderkit-dump 26.2 --target @system
privateheaderkit-dump 26.2 --target @all

# "All frameworks" + "one SystemLibrary bundle"
privateheaderkit-dump 26.2 --target @frameworks --target PreferenceBundles/Foo.bundle

# Disable nested bundle dumping
privateheaderkit-dump 26.2 --target SafariShared --no-nested
```

When `--layout headers` (default), output bundle directory suffixes are stripped for easier searching:
`.framework`, `.app`, `.bundle`, `.xpc`, `.appex`.

### 4) List runtimes / devices (iOS only)

```
privateheaderkit-dump --list-runtimes
privateheaderkit-dump --list-devices --runtime 26.0.1
```

#### Options

| Option | Description |
| --- | --- |
| `--platform <ios\|macos>` | Target platform (default: `ios`; you can also set `PH_PLATFORM`) |
| `--device <udid\|name>` | Choose a simulator device |
| `--out <dir>` | Output directory |
| `--force` | Always dump headers even if they already exist (successful frameworks replace their output directory; failures keep existing output and are recorded in `_failures.txt`) |
| `--skip-existing` | Skip frameworks that already exist (useful to override `PH_FORCE=1`) |
| `--exec-mode <host\|simulator>` | Force execution mode |
| `--target <value>` | Select dump target (repeatable, additive). If omitted, it's the same as `@frameworks`. Presets: `@frameworks`, `@system`, `@all`. |
| `--no-nested` | Disable nested `XPCServices` / `PlugIns` bundle dumping (default: enabled) |
| `--layout <bundle\|headers>` | Output layout (`bundle` keeps `.framework` dirs, `headers` removes the `.framework` suffix) |
| `--framework <name>` | (Legacy) Dump only the exact framework name (repeatable, `.framework` optional) |
| `--filter <substring>` | (Legacy) Substring filter for framework names (repeatable) |
| `--scope <frameworks\|system\|all>` | (Legacy) Dump scope (default: `frameworks`) |
| `--nested` | (Legacy) Enable nested bundle dumping (now enabled by default) |
| `--list-runtimes` | List available iOS runtimes and exit |
| `--list-devices` | List devices for a runtime and exit (use `--runtime`) |
| `--runtime <version>` | Runtime version for `--list-devices` |
| `--json` | JSON output for list commands |
| `--shared-cache` | Use dyld shared cache when dumping (enabled by default; set `PH_SHARED_CACHE=0` to disable) |
| `-D`, `--verbose` | Enable verbose logging |

`--list-runtimes`, `--list-devices`, `--runtime`, and `--device` are iOS-only options.

## Notes

- Requires Xcode command line tools (`xcrun`, `xcodebuild`).
- Simulator mode uses `xcrun simctl spawn`.
- During dumping, raw output is staged under `<out>/.tmp-<run-id>` and then moved to the final layout.
- The output directory is locked for the duration of a run to avoid concurrent writes.
- Verbose mode suppresses skipped-class logs by default; set `PH_VERBOSE_SKIP=1` to show them.
- You can override the device type used for auto-creation with `PH_DEVICE_TYPE` (device name or identifier).
- Environment overrides: `PH_PLATFORM`, `PH_EXEC_MODE`, `PH_OUT_DIR`, `PH_FORCE=1|0`, `PH_SKIP_EXISTING=1|0`, `PH_LAYOUT`, `PH_SHARED_CACHE=1|0`, `PH_VERBOSE=1|0`, `PH_VERBOSE_SKIP=1`, `PH_DEVICE_TYPE`, `PH_PROFILE=1|0`, `PH_SWIFT_EVENTS=1|0`

## License

- MIT for this workspace: see `LICENSE`.
