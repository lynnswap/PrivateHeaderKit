# PrivateHeaderKit

[English](README.md)

プライベートヘッダを生成するためのツールです。

## 使い方

### 1) ヘッダの一括ダンプ

```
./scripts/dump_headers
```

必要に応じて明示的に Python を使う場合:

```
python3 scripts/dump_headers
```

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
- `--skip-existing`: 既存ヘッダの上書きを避ける
- `--exec-mode <host|simulator>`: 実行モードを強制（デフォルトは host）
- `--category <frameworks|private>`: 対象カテゴリを限定（複数指定可）
- `--framework <name>`: 指定したフレームワークのみダンプ（複数指定可、`.framework` は省略可）
- `--filter <substring>`: フレームワーク名の部分一致フィルタ（複数指定可）
- `--layout <bundle|headers>`: 出力レイアウト（`bundle` は `.framework` を保持、`headers` は `.framework` を外す）
- `--list-runtimes`: 利用可能な iOS ランタイム一覧を表示して終了
- `--list-devices`: ランタイム内のデバイス一覧を表示して終了（`--runtime` 併用）
- `--runtime <version>`: `--list-devices` 用のランタイム指定
- `--json`: list 系の JSON 出力

## メモ

- `classdump-dyld` サブモジュールを利用します。
- サブモジュールが未初期化なら `git submodule update --init --recursive` を自動実行します。
- Python 3 が必要です。
- `simulator` モード時は `xcrun simctl spawn` 経由です。
- ダンプ中の一時出力は `<out>/.tmp-<run-id>` に作成し、最後にレイアウトへ移動します。
- 実行中は出力ディレクトリをロックして、同時書き込みを防ぎます。
- 環境変数で上書き可能: `PH_EXEC_MODE`, `PH_OUT_DIR`, `PH_SKIP_EXISTING=1`, `PH_LAYOUT`

## ライセンス

- このワークスペースは MIT: `LICENSE` を参照
- サードパーティ: `THIRD_PARTY_NOTICES.md` を参照
