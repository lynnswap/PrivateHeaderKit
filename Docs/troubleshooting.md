# Troubleshooting

## `privateheaderkit: command not found`

The default command directory is `~/.local/bin`. When it is not on `PATH`, the
installer prints a `Next steps` block for the detected login shell, including
an export for the current session. Copy those commands exactly, or open a new
terminal if the profile already contains the printed entry.

Rerunning the installer is safe and will print the guidance again when needed.
The installer does not edit or source shell profiles itself.

## No iOS or watchOS source appears in the wizard

iOS and watchOS generation require full Xcode and a matching installed
Simulator runtime. Confirm that Xcode's command-line tools are selected and
inspect the available runtimes:

```bash
xcode-select -p
xcrun simctl list runtimes
```

Install the desired iOS or watchOS runtime from Xcode settings, then rerun
`privateheaderkit`. macOS generation remains available without either runtime.
A paired physical device does not substitute for a Simulator runtime.

## More than one Simulator runtime matches `--version`

Use the interactive wizard, or add the source build identifier in automation:

```bash
privateheaderkit \
  --platform iOS \
  --version 27.0 \
  --build 24A000 \
  --out ~/PrivateHeaderKit \
  --target all
```

Replace the example platform, version, and build with a combination listed by
`xcrun simctl list runtimes`. Runtime matching is scoped to `--platform`, so iOS
and watchOS runtimes with the same version do not conflict.

## An unfinished run already exists

Run `privateheaderkit` and choose Continue or Restart. In automation, rerun with
the same plan and `--resume`, or use `--fresh` to start every selected target
again.

PrivateHeaderKit rejects an implicit decision here so that a script cannot
discard or reinterpret unfinished work accidentally.

## Legacy state or output blocks a run

Use the interactive wizard to review what will be preserved and backed up. In
automation, `--fresh` is the explicit permission to migrate. PrivateHeaderKit
does not treat legacy JSON state as resumable state and does not silently adopt
an unmanaged output directory.

See [Generation, Output, and Resume Behavior](generation.md#legacy-output) for
the migration contract.

## An install or update failed

Read the first reported validation or filesystem error. Download, build,
validation, and staging failures do not replace the active validated cohort.
If activation itself fails, the installer reports whether restoring the
previous cohort also failed.

Run the same install command again after correcting the reported cause. Do not
manually replace individual helper binaries; the public command, both simulator
helpers, and the raw macOS helper are validated and activated as one cohort.
