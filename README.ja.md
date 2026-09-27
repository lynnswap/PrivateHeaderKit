# PrivateHeaderKit

[English](README.md)

この Mac またはインストール済み iOS / watchOS Simulator runtime から、検索可能な
private header を生成します。

Apple Silicon 搭載の Mac と macOS 14 以降が必要です。iOS / watchOS のヘッダー生成には、
Xcode と対応するインストール済み Simulator runtime が必要です。実機は生成元にできません。
ソースからビルドする場合は、Swift 6.3 以降と iOS / watchOS Simulator SDK を含む Xcode が必要です。

## クイックスタート

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

対応する bottle（ビルド済みパッケージ）があればそれを使い、なければソースからビルドします。
生成元を選び、すべての対象を生成するか、個別の framework・bundle・dylib 名を入力します。
出力先はデフォルトで `~/PrivateHeaderKit` です。完了時に `Headers` ディレクトリの場所を表示します。
生成したヘッダーは `generated-headers/iOS/27.0_beta_24A5390f` のように、platform と生成元ごとに保存します。

更新は `brew upgrade privateheaderkit`、削除は `brew uninstall privateheaderkit` で行います。
削除しても生成済みヘッダーは残ります。従来のインストーラーを使っている場合は、
[移行手順](Docs/installation.md#move-from-the-standalone-installer)を参照してください。

## ソースからビルド

checkout または展開したソースアーカイブで実行します。

```sh
scripts/build-release.sh --version dev
.build/distribution/privateheaderkit
```

コマンド本体と3つの内部ヘルパーをまとめてビルドします。インストールや `PATH` の変更は行いません。
必要な環境とビルドオプションは[インストール手順](Docs/installation.md)を参照してください。

## 自動実行

通常は引数なしの interactive mode を推奨します。script から使う場合は、生成条件を
すべて明示します。

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

全 option は `privateheaderkit --help` で確認できます。各例の version はインストール済み
runtime に合わせて変更してください。選択した platform で同じ version に一致する runtime
が複数ある場合は `--build <build>` も指定します。

## シンボル検索

生成後は C/C++・Objective-C・Swift のシンボル名も検索できます。

```bash
privateheaderkit search 'std::' --in ~/PrivateHeaderKit/generated-headers
```

各 image の `.symbols.tsv` に元の名前と demangle 後の名前を保存します。
完全一致には `--exact` を指定します。出力形式と取得範囲は
[シンボル検索の仕様（英語）](Docs/generation.md#symbol-search)を参照してください。

## ドキュメント

- [インストールと更新（英語）](Docs/installation.md)
- [生成、出力、resume の仕様（英語）](Docs/generation.md)
- [関数を選んでローカルで逆コンパイルする（英語）](Docs/decompilation.md)
- [トラブルシューティング（英語）](Docs/troubleshooting.md)
- [開発と release（英語）](CONTRIBUTING.md)

## ライセンス

PrivateHeaderKit は [MIT License](LICENSE) で提供します。
