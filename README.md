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

## Install and Run

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

Follow the prompts to choose a source and targets. Generated files are saved
under `~/PrivateHeaderKit`; the command prints the header directory.
For an existing standalone installation, follow the
[migration instructions](Docs/installation.md#move-from-the-standalone-installer).

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

## Update

```sh
brew update
brew upgrade privateheaderkit
```

## Guides

- [Installation, removal, and building from source](Docs/installation.md)
- [Header generation, symbol search, and automation](Docs/generation.md)
- [Function decompilation](Docs/decompilation.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [Development and releases](CONTRIBUTING.md)

[MIT License](LICENSE)
