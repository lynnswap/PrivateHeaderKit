# PrivateHeaderKit

[English](README.md)

プライベートヘッダを生成するためのツールです。

## 使い方

### 1) ヘッダの一括ダンプ

```
./scripts/dump_headers
```

必要に応じて明示的に Python を使う場合:


### 2) 引数を指定して実行

```
./scripts/dump_headers 26.2
```

デフォルト出力先は `generated-headers/iOS/<version>` です。  
`Frameworks` と `PrivateFrameworks` をまとめて出力します。

### 3) ランタイム/デバイス一覧

```
./scripts/dump_headers --list-runtimes
./scripts/dump_headers --list-devices --runtime 26.0.1
```

#### オプション

- `--device <udid|name>`: 対象シミュレーターを指定
- `--out <dir>`: 出力先を指定
- `--force`: 既存ヘッダがあっても常に再生成する
- `--exec-mode <host|simulator>`: 実行モードを強制
- `--category <frameworks|private>`: 対象カテゴリを限定（複数指定可）
- `--framework <name>`: 指定したフレームワークのみダンプ（複数指定可、`.framework` は省略可）
- `--filter <substring>`: フレームワーク名の部分一致フィルタ（複数指定可）
- `--layout <bundle|headers>`: 出力レイアウト（`bundle` は `.framework` を保持、`headers` は `.framework` を外す）
- `--list-runtimes`: 利用可能な iOS ランタイム一覧を表示して終了
- `--list-devices`: ランタイム内のデバイス一覧を表示して終了（`--runtime` 併用）
- `--runtime <version>`: `--list-devices` 用のランタイム指定
- `--json`: list 系の JSON 出力
- `--shared-cache`: dyld shared cache を使ってダンプ（デフォルト有効。無効化は `PH_SHARED_CACHE=0`）

## メモ

- このリポジトリ内の SwiftPM 実行ファイル（`classdump-dyld`）を利用します。
- Python 3 が必要です。
- `simulator` モード時は `xcrun simctl spawn` 経由です。
- ダンプ中の一時出力は `<out>/.tmp-<run-id>` に作成し、最後にレイアウトへ移動します。
- 実行中は出力ディレクトリをロックして、同時書き込みを防ぎます。
- `-D` での詳細ログ時も、スキップクラスのログはデフォルトで出さない（`PH_VERBOSE_SKIP=1` で表示）。
- 自動作成するデバイスタイプは `PH_DEVICE_TYPE` で指定可能（デバイス名または identifier）。
- 環境変数で上書き可能: `PH_EXEC_MODE`, `PH_OUT_DIR`, `PH_FORCE=1|0`, `PH_SKIP_EXISTING=1|0`, `PH_LAYOUT`, `PH_SHARED_CACHE=1|0`, `PH_VERBOSE_SKIP=1`, `PH_DEVICE_TYPE`

## ライセンス

- このワークスペースは MIT: `LICENSE` を参照
