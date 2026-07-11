# PrivateHeaderKit

[English](README.md)

iOS / macOS の private framework ヘッダを生成します。

- iOS: Simulator ランタイムと dyld shared cache から生成
- macOS: ホストの `/System/Library/{Frameworks,PrivateFrameworks}` から生成

## Rewrite 状態

PrivateHeaderKit は、ユーザーが直接使うコマンドを 1 つに寄せる前提で rewrite 中です。

```bash
privateheaderkit
```

旧 `privateheaderkit-dump` / `headerdump` / `headerdump-sim` は、user-facing command としてはインストール・案内しません。低レベル raw dump は internal helper で扱います。

## インストール

Apple Silicon Mac では、version を焼き込んだ installer から最新の release
cohort をインストールできます。

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
sh install.sh
```

installer は対応する archive と `SHA256SUMS.txt` を取得し、展開前の checksum、
3 binary の内容・architecture・platform・code signature を検証してから active
cohort を切り替えます。デフォルトの user-facing command は
`~/.local/bin/privateheaderkit` です。

`~/.local/bin` が `PATH` に入っていない場合は追加してください:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

prefix または command directory を変更する場合:

```bash
sh install.sh --prefix "$HOME/.local"
# または: $HOME を prefix、$HOME/bin を stable command directory にする
sh install.sh --bindir "$HOME/bin"
```

checkout から全 artifact を build してインストールする場合:

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

release install と source install は同じ immutable layout を使います。

```text
~/.local/bin/privateheaderkit
  -> ../libexec/privateheaderkit/current/privateheaderkit
~/.local/libexec/privateheaderkit/
  current -> versions/<version+content-sha256>
  versions/<version+content-sha256>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    release.json
```

public command は `privateheaderkit` だけです。raw dump helper は常に同じ検証済み
cohort から解決します。更新時は最新の `install.sh` を再取得して実行するか、source
checkout を更新して `swift run -c release privateheaderkit-install` を再実行します。
build・download・validation・staging のどこかで失敗した場合、active な `current`
pointer は変更されません。tag のない source checkout は commit を含む
`0.0.0-dev.<short-commit>` version namespace を使います。

## Command Surface

```bash
privateheaderkit
privateheaderkit --help
```

`privateheaderkit` を引数なしで実行すると interactive generation flow を開始し、`~/PrivateHeaderKit` に出力します。automation / CI では generation option を直接渡します。

```bash
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --device "iPhone 17" --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
```

iOS では `--version` / `--build` から利用可能な Simulator runtime を解決し、device を選択・boot して internal simulator helper で raw dump します。指定した version の runtime が複数 install されている場合は `--build` が必須であり、`simctl` の出力順には依存しません。`--system-root` は iOS では任意です。指定した場合は、その runtime root を明示入力として使い、解決済み runtime root で黙って置き換えません。`--device <name-or-udid>` と `--sim-helper <path>` は automation 用の任意 flag です。

`--target` は comma-separated target query です。`--resume` は明示的な non-interactive resume request です。旧 `<version>` positional style は新しい public surface には含めません。

## Output Layout Contract

デフォルト出力は次の構成を予定しています。

```text
~/PrivateHeaderKit/
  ios-v1-27.0-b1-24~415355~71/
  .state/
    ios-v1-27.0-b1-24~415355~71/
      manifest.json
      runs/
```

custom output では、`--out` で output base directory を指定します。生成ヘッダは
`<output-base>/<source-storage-id>/`、state は
`<output-base>/.state/<source-storage-id>/` に置きます。storage ID は
PrivateHeaderKit が所有する versioned identifier であり、consumer は表示用 source
label から組み立てません。

## メモ

- Apple platform discovery と simulator execution には Xcode command line tools（`xcrun`, `xcodebuild`）が必要です。
- state / log / staging data は generated header tree の外に置きます。
- rewrite では、旧 CLI 互換より resume-safe execution、明示的な source identity、単一 public command を優先します。

## テスト

`swift test` は deterministic であることを期待します。通常テストは固定 fixture tree、注入された environment、stub command runner を使ってください。

simulator を起動せず、platform-neutral な Core target とその test surface を iOS 向けに compile するには、次を実行します。

```bash
PHK_IOS_SIMULATOR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PHK_IOS_SIMULATOR_TRIPLE="$(uname -m)-apple-ios17.0-simulator"
PHK_IOS_BUILD_SCRATCH="$PWD/.build/privateheaderkit-ios-compile/$PHK_IOS_SIMULATOR_TRIPLE"
swift build --scratch-path "$PHK_IOS_BUILD_SCRATCH" --sdk "$PHK_IOS_SIMULATOR_SDK" --triple "$PHK_IOS_SIMULATOR_TRIPLE" --target PrivateHeaderKitCore
swift build --scratch-path "$PHK_IOS_BUILD_SCRATCH" --sdk "$PHK_IOS_SIMULATOR_SDK" --triple "$PHK_IOS_SIMULATOR_TRIPLE" --target PrivateHeaderKitCoreTests
```

host dyld shared cache、インストール済み system app、simulator availability、runtime boot state、wall-clock time、生成済み `swiftc` binary、network access、stress loop に依存する通常テストは追加しないでください。integration smoke test にそれらが必要な場合は、`PHK_RUN_INTEGRATION_TESTS=1` のような明示 opt-in の後ろに置き、default acceptance path から外してください。

## ライセンス

- このワークスペースは MIT: `LICENSE` を参照
