# PrivateHeaderKit

[日本語](README.ja.md)

Tooling for generating private headers.

## Usage

### 1) Dump headers

```
./scripts/dump_headers
```

If you prefer explicit Python:

```
python3 scripts/dump_headers
```

### 2) Dump headers with args

```
./scripts/dump_headers 26.2
```

Default output directory is `generated-headers/iOS/<version>`.
This dumps both `Frameworks` and `PrivateFrameworks`.

### 3) List runtimes / devices

```
./scripts/dump_headers --list-runtimes
./scripts/dump_headers --list-devices --runtime 26.0.1
```

#### Options

- `--device <udid|name>`: Choose a simulator device
- `--out <dir>`: Output directory
- `--force`: Always dump headers even if they already exist
- `--exec-mode <host|simulator>`: Force execution mode (default: host if available)
- `--framework <name>`: Dump only the exact framework name (repeatable, `.framework` optional)
- `--filter <substring>`: Substring filter for framework names (repeatable)
- `--layout <bundle|headers>`: Output layout (`bundle` keeps `.framework` dirs, `headers` removes the `.framework` suffix)
- `--list-runtimes`: List available iOS runtimes and exit
- `--list-devices`: List devices for a runtime and exit (use `--runtime`)
- `--runtime <version>`: Runtime version for `--list-devices`
- `--json`: JSON output for list commands

## Notes

- Uses the `classdump-dyld` submodule.
- If the submodule isn't initialized, the script runs `git submodule update --init --recursive`.
- Requires Python 3.
- Simulator mode uses `xcrun simctl spawn`.
- During dumping, raw output is staged under `<out>/.tmp-<run-id>` and then moved to the final layout.
- The output directory is locked for the duration of a run to avoid concurrent writes.
- Environment overrides: `PH_EXEC_MODE`, `PH_OUT_DIR`, `PH_FORCE=1|0`, `PH_SKIP_EXISTING=1|0`, `PH_LAYOUT`

## License

- MIT for this workspace: see `LICENSE`.
- Third-party: see `THIRD_PARTY_NOTICES.md`.
