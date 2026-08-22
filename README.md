# PrivateHeaderKit

[日本語](README.ja.md)

Generate searchable private headers from this Mac or an installed iOS or
watchOS Simulator runtime.

Requires macOS 14 or later. Prebuilt releases require Apple Silicon. iOS and
watchOS generation require Xcode and a matching installed Simulator runtime;
physical devices are not generation sources. Source installation requires
Swift 6.3 and Xcode with iOS and watchOS Simulator SDKs.

## Quick Start

```bash
(
  privateheaderkit_installer="$(
    curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
  )" &&
  printf '%s\n' "$privateheaderkit_installer" | sh
)
```

The installer is downloaded completely before execution and is not written to
the current directory.

If the installer prints a `Next steps` block, follow it instead of the command
below. Otherwise run:

```bash
privateheaderkit
```

Choose a source, then generate all targets or enter specific framework, bundle,
or dylib names. PrivateHeaderKit writes to `~/PrivateHeaderKit` by default and
prints the exact `Headers` directory for the generated files.
Generated headers are grouped by platform and exact source, for example
`generated-headers/iOS/27.0_beta_24A5390f`.

The installer does not edit shell profiles.

## Build from Source

Build and run the source installer from the checkout:

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

The installer builds `privateheaderkit` and three internal helpers from the same
checkout. It accepts the same `--prefix` and `--bindir` options as `install.sh`.

## Install Options

<details>
<summary>Custom directories</summary>

Install the command in `~/bin`:

```bash
(
  privateheaderkit_installer="$(
    curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
  )" &&
  printf '%s\n' "$privateheaderkit_installer" | sh -s -- --bindir ~/bin
)
```

</details>

## Automation

The no-argument command is the recommended interactive path. For scripts, pass
all generation inputs explicitly:

```bash
privateheaderkit \
  --platform macOS \
  --version "$(sw_vers -productVersion)" \
  --build "$(sw_vers -buildVersion)" \
  --system-root / \
  --out ~/PrivateHeaderKit \
  --target AppKit,Foundation
```

```bash
privateheaderkit \
  --platform iOS \
  --version 27.0 \
  --out ~/PrivateHeaderKit \
  --target SwiftUI,UIKit
```

```bash
privateheaderkit \
  --platform watchOS \
  --version 27.0 \
  --out ~/PrivateHeaderKit \
  --target WatchKit
```

Use `privateheaderkit --help` for the complete option list. Replace each example
version with an installed runtime version. If more than one runtime for the
selected platform matches a version, add `--build <build>`.

## Documentation

- [Installation and updates](Docs/installation.md)
- [Generation, output, and resume behavior](Docs/generation.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [Development and releases](CONTRIBUTING.md)

## License

PrivateHeaderKit is available under the [MIT License](LICENSE).
