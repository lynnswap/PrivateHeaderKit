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

## Install, Update, and Remove

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

Update through Homebrew:

```sh
brew update
brew upgrade privateheaderkit
```

Remove the installed tool:

```sh
brew uninstall privateheaderkit
```

Uninstalling the Formula does not remove generated headers or the data under
`~/PrivateHeaderKit`. Homebrew manages the command's location and version links;
do not run a separate updater over a Homebrew-managed installation.

## Build from Source

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

## Move from the Standalone Installer

Run the familiar installer once to install the Homebrew Formula and switch the
old command path to it:

```sh
curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh
```

The installer checks the new command, backs up the recognized old entry point,
and makes that path follow Homebrew upgrades. Existing absolute command paths
continue to work. Use the original `--prefix` or `--bindir` for a custom old
installation; piped invocations can pass these as `sh -s -- --prefix /path`.
`PREFIX` and `BINDIR` remain supported. `--dry-run` reports the locations without
running Homebrew or changing files.

The old `~/.local/libexec/privateheaderkit` payloads remain available to processes
that are still running. Generated headers under `~/PrivateHeaderKit` and custom
output directories are preserved. The installer reports its backup directory and
restores old entry points if migration fails. Restart running commands to use the
new installation. Future updates use `brew upgrade privateheaderkit`.

The Formula itself does not scan standalone installations or change shell
profiles. The release `install.sh` performs this one-time handoff; the old
`privateheaderkit-install` executable is no longer distributed.
