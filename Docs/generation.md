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
creates and boots one dedicated simulator device for the run, then deletes that
exact device after generation, failure, or interruption. It does not use a
connected iPhone or Apple Watch as a generation source. An explicit `--device`
selects an existing borrowed simulator instead; PrivateHeaderKit never deletes
that device.

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
<output-base>/generated-headers/<platform>/<release-directory>/
```

Platform directories use the displayed Apple platform name: `iOS`, `watchOS`,
or `macOS`. Release directories include the exact build when it is available:

```text
iOS/26.4_23E244/
iOS/27.0_beta_24A5390f/
```

Release directory fields use underscores so paths do not require shell quoting.
PrivateHeaderKit derives the `beta` field from the source runtime's seed
metadata, not from the build suffix; this keeps lowercase-suffixed public
releases out of the beta namespace. Installed metadata does not provide a beta
number, so the build disambiguates beta sources. Older Simulator runtimes that
omit `RestoreVersion.plist` are treated as non-seed releases. An unreadable or
malformed metadata file, or missing macOS metadata, stops generation instead of
publishing under a guessed name.

The complete output base is:

```text
<output-base>/
  generated-headers/
    <platform>/
      <release-directory>/
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
`generation.sqlite`, outside the published header tree. The `.privateheaderkit`
tree is an internal recovery artifact; consumers should use only the printed
`Headers` directory.

PrivateHeaderKit automatically relocates its previous managed live directory,
`generated-headers/<source-storage-id>`, to the platform/release layout while
holding the same source lease. The whole directory is renamed atomically so
completed targets from an interrupted run remain resumable. If both the old
and new directories exist, PrivateHeaderKit leaves both unchanged and stops;
it never guesses how to merge or overwrite them. Unrelated siblings under
`generated-headers` are not part of this relocation.

If the printed header directory is removed while the authenticated current
generation remains available, the next run restores the missing published
files before deciding whether to continue or restart. PrivateHeaderKit does not
create a top-level source link.

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

Resume compatibility is bound to the PrivateHeaderKit producer version emitted
by the raw helper, the selected source and Simulator runtime, generation
options, and the loaded shared-cache cohort when used. A simulator device UDID
is only a temporary execution address and does not affect compatibility. After
upgrading from state created before producer-version tracking, select Restart or
use `--fresh` once; existing published headers remain available until replaced.

## Legacy Output

PrivateHeaderKit does not silently adopt either legacy form:

- Older JSON state is not imported as resumable state. A fresh migration
  creates `generation.sqlite` and leaves the JSON paths in place.
- A pre-rewrite `<output-base>/<source-storage-id>` directory is inventoried and
  copied into the draft generation. A fresh migration publishes the new
  generation, then atomically moves the original directory under
  `legacy-backups`; nothing replaces it at the output-base root.

Older PrivateHeaderKit versions created a managed
`<output-base>/<source-storage-id>` symlink to the internal current generation.
The next run for that source relocates the exact managed symlink out of the
output-base root only after the current generation has been authenticated. A
symlink with any other target, or
a regular or special file at that path, is left unchanged and stops generation.
Real directories remain subject to the explicit fresh-migration contract above.
Except for the uncommitted compatibility state described below, a real
directory that coexists with an authenticated current generation is ambiguous;
PrivateHeaderKit leaves it unchanged and stops even when `--fresh` was
requested.

Before the current pointer is switched, output validation or archival failures
leave the original directory in place. If the process stops after the switch,
startup recovery completes the exclusive move into `legacy-backups` before
resuming generation. The move uses device and file identity only to detect a
replacement during that operation; later startups authenticate the backup with
a portable checksum of its paths, item kinds, and file contents so copied or
restored output remains usable. The checksum requirement and the generation
that alone may archive the original directory are carried through every later
generation marker. This keeps deletion or corruption detectable without
allowing a later generation to archive a directory that reappears at the old
path.

When upgrading an older publication interrupted after its hidden `current`
switch but before its legacy-directory swap, no portable checksum exists.
Recovery detaches only that authenticated, uncommitted `current` pointer and
aborts its generation; it leaves the directory untouched so an explicit fresh
migration can inventory it under the current contract. An exact
`legacy-<uuid>` symlink left in `legacy-backups` by an interrupted older atomic
swap is moved into hidden managed quarantine after the current generation is
authenticated.
