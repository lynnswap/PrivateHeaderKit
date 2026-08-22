# Installation and Updates

PrivateHeaderKit installs one public command, `privateheaderkit`. The raw macOS,
iOS Simulator, and watchOS Simulator helpers are internal artifacts that are
installed and updated with it as one validated cohort.

## Requirements

GitHub release installation requires:

- an Apple Silicon Mac
- macOS 14 or later

It does not require a Swift toolchain. Generating iOS or watchOS headers
additionally requires Xcode with the matching Simulator runtime. Connected
physical devices are not generation sources.

## Install a Release

```bash
(
  privateheaderkit_installer="$(
    curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
  )" &&
  printf '%s\n' "$privateheaderkit_installer" | sh
)
```

The default command is installed at `~/.local/bin/privateheaderkit`.
The installer is downloaded completely before execution and is not written to
the current directory.

The installer checks whether the resolved command directory is already on
`PATH`. If it is missing, the installer prints a `Next steps` block with:

- a command to update the appropriate zsh or bash login profile when that
  profile can be updated safely
- an `export` command for the current shell
- the `privateheaderkit` command to run next

The installer never creates, edits, or sources a shell profile itself. For an
unknown login shell, it prints the command directory instead of guessing a
profile or shell syntax.

The release installer verifies the downloaded archive checksum, exact archive
contents, release manifest, executable hashes, architecture, platform,
permissions, and code signatures before activation.

### Custom destination

Install under another prefix. The public command is placed in `<prefix>/bin`:

```bash
(
  privateheaderkit_installer="$(
    curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
  )" &&
  printf '%s\n' "$privateheaderkit_installer" | \
    sh -s -- --prefix ~/Tools/PrivateHeaderKit
)
```

Or choose the public command directory directly:

```bash
(
  privateheaderkit_installer="$(
    curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
  )" &&
  printf '%s\n' "$privateheaderkit_installer" | sh -s -- --bindir ~/bin
)
```

Choose either `--prefix` or `--bindir`. The installer resolves `~`, relative
paths, and symlinked ancestors before installing and reporting the command
location.

### Install a specific release

Replace `<version>` with a release tag such as `v1.2.3`:

```text
https://github.com/lynnswap/PrivateHeaderKit/releases/download/<version>/install.sh
```

## Install from Source

Source installation builds the public command and three internal helpers from
the same checkout:

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

This path requires Swift 6.3 and Xcode with `xcrun`, the iOS Simulator SDK, and
the watchOS Simulator SDK because the installed cohort always includes both
simulator helpers. It does not require either runtime merely to build the
helpers, and it does not download release assets. `--prefix` and `--bindir` are
also available for source installation.

## Update

Run the release installation command again, or update the source checkout and
rerun the source installation command above. Preserve the same `--prefix` or
`--bindir` option when updating a custom destination.

Release and source installation both publish an immutable cohort and switch
the stable command only after the complete cohort passes validation. Download,
build, validation, or staging failures leave the previous cohort active; an
activation failure attempts to restore it and reports any restoration failure.

## Installed Layout

The default layout is:

```text
~/.local/bin/privateheaderkit
  -> ../libexec/privateheaderkit/current/privateheaderkit
~/.local/libexec/privateheaderkit/
  current -> versions/<version>+<cohort-sha256>
  versions/<version>+<cohort-sha256>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    privateheaderkit-watch-sim-helper
    release.json
```

Only `privateheaderkit` is a public command. The helpers are always resolved
through the active validated cohort.

After activating a validated cohort, the installer removes the retired
`privateheaderkit-dump`, `headerdump`, and `headerdump-sim` commands from the
selected command directory. Release and source installation use the same
cleanup path. These names are reserved PrivateHeaderKit installation paths;
choosing a custom `--prefix` or `--bindir` also authorizes their removal from
that selected command directory.

An older direct install containing all three executables is migrated under the
installer lock. Partial, ambiguous, or modified legacy install layouts are
rejected instead of guessed. An interrupted install migration is recovered
from its recorded intent on the next install. Generation-state and output
migration is a separate contract described in
[Generation, Output, and Resume Behavior](generation.md#legacy-output).
