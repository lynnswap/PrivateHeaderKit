# Installation and Updates

PrivateHeaderKit is distributed through the `lynnswap/tap` Homebrew Formula.
Homebrew installs the public `privateheaderkit` command together with the
private macOS, iOS Simulator, watchOS Simulator, and iPhoneOS helpers and their required
Swift compatibility libraries.

## Requirements

- An Apple Silicon Mac running macOS 26 or later for supported Homebrew
  distribution and CI verification. The executable deployment target remains
  macOS 14; older systems are outside that support range rather than explicitly
  rejected by the executable.
- Homebrew.
- To build from source: Swift 6.3 or later and Xcode with the iOS Simulator,
  watchOS Simulator, and iPhoneOS SDKs.
- To generate from an iOS or watchOS Simulator: Xcode and the corresponding
  installed Simulator runtime.
- To generate from an iPhoneOS SSH peer: an SSH server, `tar`, and permission
  to execute the bundled helper on the peer. See [SSH generation](generation.md#iphoneos-over-ssh).

The Formula requires Xcode 26.4 or later when building from source; Xcode 26.4
includes Swift 6.3. Xcode's own [host macOS requirements](https://developer.apple.com/xcode/system-requirements)
apply to source builds separately from the tool's runtime minimum.
A matching Homebrew bottle avoids the source build and its toolchain requirements.
Bottles use Homebrew's normal registration for the macOS 26 build host. If no
matching bottle is available, Homebrew attempts a source build, which still needs
a host OS supported by the required Xcode. Retaining the macOS 14 deployment
target does not promise Homebrew installation on older systems.

## Install, update, and remove

For a new installation:

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

If you used the standalone installer, complete the
[one-time migration](#move-from-the-standalone-installer) before using these update commands:

```sh
brew update
brew upgrade lynnswap/tap/privateheaderkit
privateheaderkit --tool-version
```

Remove the installed tool:

```sh
brew uninstall privateheaderkit
```

Uninstalling the Formula does not remove generated headers or the data under
`~/PrivateHeaderKit`. Homebrew manages the command's location and version links;
do not run a separate updater over a Homebrew-managed installation.

## Move from the standalone installer

If you previously used the shell installer or `privateheaderkit-install`, run
the migration installer once. This is also needed if you have already installed
the Homebrew Formula: `brew install` alone leaves the old command path in place.

```sh
curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh
```

The installer installs or updates the Formula, checks its command, and switches
recognized old entry points in `~/.local/bin` to Homebrew links. Existing absolute
command paths then follow Homebrew upgrades. The old entry points are backed up;
the installer prints the backup directory and attempts to restore them if the
switch fails.

Generated headers under `~/PrivateHeaderKit` and custom output directories are
preserved. Old payloads under `~/.local/libexec/privateheaderkit` also remain
available to processes that are still running. Restart those commands after
migration to use the Homebrew installation.

### Custom installation directories

Pass the directory used by the old installer. For example, if the command was
installed in `~/bin`:

```sh
curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh -s -- --bindir "$HOME/bin"
```

You can also pass the original `--prefix /path/to/prefix`, which selects its
`bin` subdirectory. `PREFIX` and `BINDIR` remain supported. Only the selected
directory is migrated; repeat the command with each old `--bindir` if you keep
installations in multiple locations.

### Preview and verify the migration

Preview the affected paths without running Homebrew or changing files:

```sh
curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh -s -- --dry-run
```

Add the same `--bindir` or `--prefix` when previewing a custom installation.
After migration, check the running version and command paths:

```sh
privateheaderkit --tool-version
type -a privateheaderkit
```

Use `--tool-version` to check the CLI version. The separate `--version` option
selects the source OS version for header generation.

Future updates use `brew upgrade lynnswap/tap/privateheaderkit`. The release
`install.sh` performs the one-time migration; the old `privateheaderkit-install`
executable is no longer distributed.

## Build from source

Build all five executables from a checkout or extracted source archive:

```sh
scripts/build-release.sh --version dev
.build/distribution/privateheaderkit
```

For a released source archive, pass its release version instead of `dev`.
The build uses the revisions in `Package.resolved` and does not require an
installed Simulator runtime or a Git checkout. The output directory contains
the public command, four helpers, and their Swift compatibility library
directories; keep them together when running the built command.
Use `--output-dir <directory>` to select another build output directory.
This build command does not install or change `PATH`.

To build only the iPhoneOS helper:

```sh
scripts/build-release.sh --version dev --platform iphoneos
```

The staged helper is `privateheaderkit-device-helper`; its Swift libraries are
in `privateheaderkit-runtime-iphoneos`. When running the CLI from a source
checkout, SSH generation builds this helper automatically. Installed
distributions use the bundled helper.

To build the published Formula from source under Homebrew:

```sh
brew install --build-from-source lynnswap/tap/privateheaderkit
```
