# Generation, Output, and Resume Behavior

## Interactive Generation

Run:

```bash
privateheaderkit
```

The wizard guides you through:

1. an installed iOS or watchOS Simulator runtime, or the current macOS
   installation
2. all available targets or a comma-separated list of target names
3. Continue or Restart when compatible unfinished work exists

The default output base is `~/PrivateHeaderKit`. The command prints the concrete
header directory when a run starts and again in the completion summary.

macOS generation works from the host system. iOS and watchOS generation require
Xcode, `xcrun`, `simctl`, and the selected Simulator runtime. PrivateHeaderKit
selects and boots a compatible simulator device for the run. It does not use a
connected iPhone or Apple Watch as a generation source.

## Automation

Supplying any generation option disables the wizard. Automation must provide
all required inputs.

### macOS

```bash
privateheaderkit \
  --platform macOS \
  --version "$(sw_vers -productVersion)" \
  --build "$(sw_vers -buildVersion)" \
  --system-root / \
  --out ~/PrivateHeaderKit \
  --target AppKit,Foundation
```

### iOS

```bash
privateheaderkit \
  --platform iOS \
  --version 27.0 \
  --out ~/PrivateHeaderKit \
  --target SwiftUI,UIKit
```

### watchOS

```bash
privateheaderkit \
  --platform watchOS \
  --version 27.0 \
  --out ~/PrivateHeaderKit \
  --target WatchKit
```

`--platform`, `--version`, `--out`, and `--target` are required in automation
mode. `--system-root` is also required for macOS. For iOS and watchOS,
PrivateHeaderKit resolves the runtime root; supply `--build` when more than one
runtime for the selected platform matches a version.

| Option | Meaning |
| --- | --- |
| `--platform iOS\|watchOS\|macOS` | Source platform. |
| `--version <version>` | Source OS version. |
| `--build <build>` | Source build identifier; needed for ambiguous Simulator runtime versions. |
| `--system-root <path>` | Runtime root; required for macOS and optional as a Simulator override. |
| `--out <path>` | Output base for generated headers and state. |
| `--target all\|<query>` | All targets or comma-separated target names. |
| `--device <name-or-udid>` | Preferred compatible iOS or watchOS Simulator device. |
| `--sim-helper <path>` | Explicit helper for the selected Simulator platform. |
| `--resume` | Continue the latest compatible unfinished plan. |
| `--fresh` | Start a new run and permit explicit legacy migration. |

`--resume` and `--fresh` are mutually exclusive. Run `privateheaderkit --help`
for the command's generated reference.

## Output Contract

Consumers should use only the concrete directory printed as `Headers`:

```text
<output-base>/generated-headers/<source-storage-id>/
```

The storage ID is versioned and owned by PrivateHeaderKit. Do not construct it
from the displayed source name.

The complete output base is:

```text
<output-base>/
  <source-storage-id> -> .privateheaderkit/<source-storage-id>/current
  generated-headers/
    <source-storage-id>/
      Frameworks/...
      PrivateFrameworks/...
      SystemLibrary/...
      usr/lib/...
  .privateheaderkit/
    <source-storage-id>/
      current -> generations/<generation-id>
      generations/<generation-id>/...
      legacy-backups/...
  .state/
    <source-storage-id>/generation.sqlite
```

Completed targets are published into `generated-headers` one target at a time.
If a later target or finalization fails, already published targets remain
available. Failed or interrupted targets retain their last successfully
published files. The immutable generation under `.privateheaderkit` is a
recovery snapshot, not a visibility gate for generated headers.

Objective-C header generation reads only the directly adopted protocol names
needed by class, category, and protocol declarations. Protocol metadata reads
are range-checked and traversal is bounded; an unreadable reference, cycle, or
safety-limit cutoff preserves the metadata that was decoded successfully.
Loaded-image reads of relative method/property list-of-lists consult each
entry's runtime loaded state, while file-backed reads inspect every structurally
valid entry. Both preserve outer-table order and validate the outer table and
each nonempty inner member table before decoding; an empty inner list does not
require an otherwise unused entry size. One malformed loaded list preserves its
valid siblings and produces a typed member-list degradation; unloaded lists are
skipped without warning. Once that target is published, PrivateHeaderKit reports
the precise owner and degradation as an `objc-metadata-warning` and persists the
warning in `generation.sqlite`. A bounded diagnostics report records when
additional warnings were omitted, so malformed metadata cannot grow process
output without limit. Live warning presentation is also capped across the run;
one aggregate warning points to the retained per-target details in the database.

State, attempts, publication intent, and run diagnostics are stored in
`generation.sqlite`, outside the published header tree. The top-level source
link and `.privateheaderkit` tree are internal recovery artifacts; consumers
should not use them instead of the printed `Headers` directory.

If the printed header directory or top-level source link is removed while the
authenticated current generation remains available, the next run recreates
the managed link and restores the missing published files before deciding
whether to continue or restart.

## Continue or Restart

- `--resume` continues the latest compatible plan and runs only unfinished or
  missing targets. A changed plan or smaller selected target set is rejected.
- `--fresh` starts a new run for every selected target. It also permits an
  explicit migration from legacy state or output.
- With neither flag, automation starts a new run when no prior state exists.
  Compatible completed state may be reused, but unfinished state requires an
  explicit `--resume` or `--fresh` decision.

The interactive wizard presents the same Continue or Restart choice when it
finds compatible unfinished work.

## Legacy Output

PrivateHeaderKit does not silently adopt either legacy form:

- Older JSON state is not imported as resumable state. A fresh migration
  creates `generation.sqlite` and leaves the JSON paths in place.
- An unmanaged output directory is inventoried and copied into the draft
  generation. A fresh migration atomically publishes the managed path and
  keeps the original directory under `legacy-backups`.

If output validation or the atomic swap cannot be completed, the original
output path is left in place and migration fails.
