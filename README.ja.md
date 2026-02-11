# PrivateHeaderKit

[English](README.md)

iOS / macOS の private framework ヘッダを生成します。

- iOS: Simulator ランタイム（dyld shared cache）から生成
- macOS: ホストの `/System/Library/{Frameworks,PrivateFrameworks}` から生成

## インストール

```bash
swift run -c release privateheaderkit-install
```

既定では `~/.local/bin` に以下のバイナリをインストールします:

- `privateheaderkit-dump`
- `headerdump`（host）
- `headerdump-sim`（iOS Simulator）

`~/.local/bin` が `PATH` に入っていない場合は追加してください:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

配置先を変更したい場合:

```bash
swift run -c release privateheaderkit-install --prefix "$HOME/.local"
# または
swift run -c release privateheaderkit-install --bindir "$HOME/bin"
```

ビルド済みのバイナリを直接実行したい場合:

```bash
swift build -c release --product privateheaderkit-install
"$(swift build -c release --show-bin-path)/privateheaderkit-install" --bindir "$HOME/bin"
```

## 使い方

### 1) ヘッダの一括ダンプ

```
privateheaderkit-dump
```

### 2) 引数を指定して実行

```
privateheaderkit-dump 26.2
```

デフォルト出力先は `~/PrivateHeaderKit/generated-headers/iOS/<version>` です。  
`Frameworks` と `PrivateFrameworks` をまとめて出力します。  
（`--out` / `PH_OUT_DIR` に指定した相対パスはカレントディレクトリを基準に解釈されます。従来どおりリポジトリ配下に出したい場合は、リポジトリrootで実行して `--out generated-headers/iOS/<version>` を指定するか `PH_OUT_DIR` を指定してください）

### 3) macOS ヘッダをダンプ

```
privateheaderkit-dump --platform macos
```

デフォルト出力先は `~/PrivateHeaderKit/generated-headers/macOS/<productVersion>` です。

### 4) ランタイム/デバイス一覧（iOS専用）

```
privateheaderkit-dump --list-runtimes
privateheaderkit-dump --list-devices --runtime 26.0.1
```

#### オプション

- `--platform <ios|macos>`: 対象プラットフォーム（デフォルトは `ios`。`PH_PLATFORM` でも指定可）
- `--device <udid|name>`: 対象シミュレーターを指定
- `--out <dir>`: 出力先を指定
- `--force`: 既存ヘッダがあっても常に再生成する（成功したフレームワークは出力を丸ごと置換。失敗分は既存出力を残し `_failures.txt` に記録）
- `--skip-existing`: 既に出力済みのフレームワークはスキップ（`PH_FORCE=1` を一時的に打ち消したい場合など）
- `--exec-mode <host|simulator>`: 実行モードを強制
- `--framework <name>`: 指定したフレームワークのみダンプ（複数指定可、`.framework` は省略可）
- `--filter <substring>`: フレームワーク名の部分一致フィルタ（複数指定可）
- `--layout <bundle|headers>`: 出力レイアウト（`bundle` は `.framework` を保持、`headers` は `.framework` を外す）
- `--list-runtimes`: 利用可能な iOS ランタイム一覧を表示して終了
- `--list-devices`: ランタイム内のデバイス一覧を表示して終了（`--runtime` 併用）
- `--runtime <version>`: `--list-devices` 用のランタイム指定
- `--json`: list 系の JSON 出力
- `--shared-cache`: dyld shared cache を使ってダンプ（デフォルト有効。無効化は `PH_SHARED_CACHE=0`）
- `-D`, `--verbose`: 詳細ログ

`--list-runtimes` / `--list-devices` / `--runtime` / `--device` は iOS 専用オプションです。

## メモ

- Xcode command line tools（`xcrun`, `xcodebuild`）が必要です。
- `simulator` モード時は `xcrun simctl spawn` 経由です。
- ダンプ中の一時出力は `<out>/.tmp-<run-id>` に作成し、最後にレイアウトへ移動します。
- 実行中は出力ディレクトリをロックして、同時書き込みを防ぎます。
- `-D` での詳細ログ時も、スキップクラスのログはデフォルトで出さない（`PH_VERBOSE_SKIP=1` で表示）。
- 自動作成するデバイスタイプは `PH_DEVICE_TYPE` で指定可能（デバイス名または identifier）。
- 環境変数で上書き可能: `PH_PLATFORM`, `PH_EXEC_MODE`, `PH_OUT_DIR`, `PH_FORCE=1|0`, `PH_SKIP_EXISTING=1|0`, `PH_LAYOUT`, `PH_SHARED_CACHE=1|0`, `PH_VERBOSE=1|0`, `PH_VERBOSE_SKIP=1`, `PH_DEVICE_TYPE`, `PH_PROFILE=1|0`, `PH_SWIFT_EVENTS=1|0`

## ライセンス

- このワークスペースは MIT: `LICENSE` を参照
