# Troubleshooting

## Check the running version

```sh
privateheaderkit --tool-version
```

Include this build version in bug reports. `--tool-version` prints the version
embedded in the running CLI and exits without discovering sources or preparing
helpers. The separate `--version <version>` option selects the source OS for
generation.

## `privateheaderkit: command not found`

Check the installed Formula and the command paths:

```sh
brew list --versions privateheaderkit
type -a privateheaderkit
"$(brew --prefix privateheaderkit)/bin/privateheaderkit" --help
```

If the direct command works, complete Homebrew's shell setup so its `bin`
directory is on `PATH`. If an older standalone command appears first, follow
the [migration steps](installation.md#move-from-the-standalone-installer).

## No iOS or watchOS source appears in the wizard

Check the wizard's `Unavailable sources` section for a discovery or metadata
error. Other readable sources remain selectable. An explicitly selected source
with unreadable metadata still stops generation rather than guessing its identity.

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

For an all-target run, use `privateheaderkit` and choose Continue or Restart.
In automation, use `--target all --resume` to continue or `--target all --fresh`
to restart. Named targets are always regenerated and do not require either flag.

PrivateHeaderKit rejects an implicit decision here so that a script cannot
discard or reinterpret unfinished work accidentally.

## Output from an earlier version is still on disk

This version does not read or migrate older output layouts, and it no longer
uses the `.privateheaderkit` directory. See
[Output From Earlier Versions](generation.md#output-from-earlier-versions) for
what can be deleted.

## An install or update failed

Read Homebrew's reported download, build, or link error. If Homebrew is building
from source, check that Xcode supplies Swift 6.3 or later and both iOS and watchOS
Simulator SDKs. Simulator runtimes are needed for generation, not for building.

After correcting the reported cause, retry `brew install`, `brew upgrade`, or
`brew reinstall privateheaderkit` as appropriate. Keep the CLI and its helpers
under Homebrew management instead of replacing individual files. Generated
headers and other data under `~/PrivateHeaderKit` are independent of the Formula.
