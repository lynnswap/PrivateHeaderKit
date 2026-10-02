# PrivateHeaderKit

[日本語](README.ja.md)

A CLI for generating private headers and searching symbol names on macOS, iOS,
and watchOS. Sources are this Mac's macOS installation or installed Simulator
runtimes.

Homebrew distribution and CI verification target Apple Silicon Macs running
macOS 26 or later. iOS and watchOS generation also requires Xcode and the matching
Simulator runtime.

## Install and Run

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

Follow the prompts to choose a source and targets. Generated files are saved
under `~/PrivateHeaderKit`; the command prints the header directory.
For an existing standalone installation, follow the
[migration instructions](Docs/installation.md#move-from-the-standalone-installer).

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
