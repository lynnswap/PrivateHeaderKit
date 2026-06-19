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

旧 `privateheaderkit-dump` / `headerdump` / `headerdump-sim` は、user-facing command としてはインストール・案内しません。低レベル raw dump は `privateheaderkit` の hidden internal mode として保持します。

## インストール

```bash
swift run -c release privateheaderkit install
```

デフォルトでは、user-facing command として単一の `privateheaderkit` バイナリを `~/.local/bin` にインストールします。
iOS Simulator raw dump 用の internal helper は `~/.local/libexec/privateheaderkit/privateheaderkit-sim-helper` にインストールします。

`~/.local/bin` が `PATH` に入っていない場合は追加してください:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

配置先を変更したい場合:

```bash
swift run -c release privateheaderkit install --prefix "$HOME/.local"
# または
swift run -c release privateheaderkit install --bindir "$HOME/bin"
```

ビルド済みのバイナリを直接実行したい場合:

```bash
swift build -c release --product privateheaderkit
"$(swift build -c release --show-bin-path)/privateheaderkit" install --bindir "$HOME/bin"
```

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

iOS では `--version` / `--build` から利用可能な Simulator runtime を解決し、device を選択・boot して internal simulator helper で raw dump します。`--system-root` は iOS では任意です。指定した場合は、その runtime root を明示入力として使い、解決済み runtime root で黙って置き換えません。`--device <name-or-udid>` と `--sim-helper <path>` は automation 用の任意 flag です。

`--target` は comma-separated target query です。`--resume` は明示的な non-interactive resume request です。旧 `<version>` positional style は新しい public surface には含めません。

## Output Layout Contract

デフォルト出力は次の構成を予定しています。

```text
~/PrivateHeaderKit/
  generated-headers/
    iOS27.0(24A5355q)/
  .state/
    iOS27.0(24A5355q)/
      manifest.json
      runs/
```

custom output では、`--out` と `PH_OUT_DIR` は artifact root ではなく output base directory として扱います。生成ヘッダは `<output-base>/<source-label>/`、state は `<output-base>/.state/<source-label>/` に置きます。

## メモ

- Apple platform discovery と simulator execution には Xcode command line tools（`xcrun`, `xcodebuild`）が必要です。
- state / log / staging data は generated header tree の外に置きます。
- rewrite では、旧 CLI 互換より resume-safe execution、明示的な source identity、単一 public command を優先します。

## テスト

`swift test` は deterministic であることを期待します。通常テストは固定 fixture tree、注入された environment、stub command runner を使ってください。

host dyld shared cache、インストール済み system app、simulator availability、runtime boot state、wall-clock time、生成済み `swiftc` binary、network access、stress loop に依存する通常テストは追加しないでください。integration smoke test にそれらが必要な場合は、`PHK_RUN_INTEGRATION_TESTS=1` のような明示 opt-in の後ろに置き、default acceptance path から外してください。

## ライセンス

- このワークスペースは MIT: `LICENSE` を参照
