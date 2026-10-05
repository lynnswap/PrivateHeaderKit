# PrivateHeaderKit

[日本語](README.ja.md)

A CLI for generating private headers and searching symbol names on macOS, iOS,
and watchOS. Sources are this Mac's macOS installation, installed Simulator
runtimes, or an iPhoneOS environment reachable over SSH, such as a jailbroken
iPhone or vphone.

Homebrew distribution and CI verification target Apple Silicon Macs running
macOS 26 or later. Simulator generation also requires Xcode and the matching
runtime. SSH generation requires an SSH server, `tar`, and permission to run the
bundled iPhoneOS helper on the peer.

## Quick start

### Install

For a new installation, use [Homebrew](https://brew.sh/):

```sh
brew install lynnswap/tap/privateheaderkit
```

> [!NOTE]
> If you previously used the shell installer or `privateheaderkit-install`, run
> this command once to migrate to Homebrew, even if you have already run `brew install`:
>
> ```sh
> curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh
> ```
>
> Restart any running commands afterward. Generated headers are preserved.
> For an old custom installation directory, see the
> [migration options](Docs/installation.md#custom-installation-directories).

### Generate headers

```sh
privateheaderkit
```

Follow the prompts to choose a source and targets. Generated files are saved
under `~/PrivateHeaderKit`; the command prints the header directory.

## Generate over SSH

To generate from a configured SSH destination:

```sh
privateheaderkit --ssh iphone-se --out ~/PrivateHeaderKit --target SpringBoard,SpringBoardUI
```

PrivateHeaderKit reads the OS version and build from the peer. See the
[SSH setup and generation guide](Docs/generation.md#iphoneos-over-ssh) for
authentication and USB forwarding.

For an already-running installed application, select its bundle identifier:

```sh
privateheaderkit --ssh iphone-se --app com.example.Sample --out ~/PrivateHeaderKit
```

See [application generation](Docs/generation.md#running-applications-over-ssh) for
PID selection and saving a Mach-O file for local analysis.

## Update a Homebrew installation

```sh
brew update
brew upgrade lynnswap/tap/privateheaderkit
privateheaderkit --tool-version
```

## Guides

- [Installation, removal, and building from source](Docs/installation.md)
- [Header generation, symbol search, and automation](Docs/generation.md)
- [Function decompilation](Docs/decompilation.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [Development and releases](CONTRIBUTING.md)

[MIT License](LICENSE)
