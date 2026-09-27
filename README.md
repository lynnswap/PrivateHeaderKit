# PrivateHeaderKit

[日本語](README.ja.md)

Generate searchable private headers and symbol lists from this Mac or an installed iOS or
watchOS Simulator runtime.

Requires an Apple Silicon Mac with macOS 14 or later. iOS and watchOS generation
require Xcode and a matching installed Simulator runtime; physical devices are
not generation sources. Building from source requires Swift 6.3 or later and
Xcode with iOS and watchOS Simulator SDKs.

## Quick Start

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

Homebrew uses a matching bottle when available, or builds from source.
Choose a source, then generate all targets or enter specific framework, bundle,
or dylib names. PrivateHeaderKit writes to `~/PrivateHeaderKit` by default and
prints the exact `Headers` directory for the generated files.
Generated headers are grouped by platform and exact source, for example
`generated-headers/iOS/27.0_beta_24A5390f`.

Update with `brew upgrade privateheaderkit`; remove with
`brew uninstall privateheaderkit`. Generated headers are kept.
For an existing standalone installation, follow the
[migration instructions](Docs/installation.md#move-from-the-standalone-installer).

## Build from Source

From a checkout or extracted source archive:

```sh
scripts/build-release.sh --version dev
.build/distribution/privateheaderkit
```

This builds the command and its three internal helpers together without
installing them. See [installation](Docs/installation.md) for requirements
and build options.

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

## Search Symbols

After generation, search C/C++, Objective-C, and Swift symbol names:

```bash
privateheaderkit search 'std::' --in ~/PrivateHeaderKit/generated-headers
```

Each image includes a `.symbols.tsv` file with original and demangled names.
Use `--exact` for a complete name. See [symbol search](Docs/generation.md#symbol-search)
for the output format and limits.

## Documentation

- [Installation and updates](Docs/installation.md)
- [Generation, output, and resume behavior](Docs/generation.md)
- [Decompile a selected function locally](Docs/decompilation.md)
- [Troubleshooting](Docs/troubleshooting.md)
- [Development and releases](CONTRIBUTING.md)

## License

PrivateHeaderKit is available under the [MIT License](LICENSE).
