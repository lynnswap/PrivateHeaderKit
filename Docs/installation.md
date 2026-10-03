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
checkout, SSH generation builds this helper automatically if no staged helper
is beside the CLI. Installed distributions use the bundled helper.

To build the published Formula from source under Homebrew:

```sh
brew install --build-from-source lynnswap/tap/privateheaderkit
```

## Move from the Standalone Installer

New releases no longer provide the standalone installer or the
`privateheaderkit-install` executable. Existing installations and already
published release assets remain available until you choose to remove them.

1. Install the Formula and check the new command directly:

   ```sh
   brew install lynnswap/tap/privateheaderkit
   "$(brew --prefix privateheaderkit)/bin/privateheaderkit" --help
   ```

2. Inspect the commands selected by your shell:

   ```sh
   type -a privateheaderkit
   ls -l ~/.local/bin/privateheaderkit
   ```

3. If that path is the old standalone command, remove that command link. After
   confirming the Homebrew installation works, you may also remove the old
   `~/.local/libexec/privateheaderkit` installation directory. If you used a
   custom prefix or bindir, inspect and remove only the corresponding old
   installation paths instead.

Keep `~/PrivateHeaderKit` and any custom output directory: they contain your
results, not the old executable installation. The Formula does not scan or
remove standalone installations and does not edit shell profiles.
