# PrivateHeaderKit

[English](README.md)

macOS・iOS・watchOS の非公開ヘッダーを生成し、シンボル名を検索する CLI ツールです。
生成元には、この Mac の macOS またはインストール済みのシミュレータランタイムを使います。

Homebrew での配布・動作確認は、macOS 26 以降の Apple Silicon 搭載 Mac が対象です。
iOS・watchOS の生成には、Xcode と対応するシミュレータランタイムも必要です。

## インストールして使う

```sh
brew install lynnswap/tap/privateheaderkit
privateheaderkit
```

起動後は画面の案内に沿って、生成元と対象を選びます。
生成物は `~/PrivateHeaderKit` 以下に保存します。ヘッダーの保存先は実行時の表示で確認できます。
従来のインストーラーを使っている場合は、[移行手順](Docs/installation.md#move-from-the-standalone-installer)を参照してください。

## 更新する

```sh
brew update
brew upgrade privateheaderkit
```

## 詳しい使い方

以下のガイドは英語です。

- [インストール・削除・ソースからのビルド](Docs/installation.md)
- [ヘッダー生成・シンボル検索・自動実行](Docs/generation.md)
- [関数の逆コンパイル](Docs/decompilation.md)
- [トラブルシューティング](Docs/troubleshooting.md)
- [開発・リリース](CONTRIBUTING.md)

[MIT License](LICENSE)
