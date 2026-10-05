# PrivateHeaderKit

[English](README.md)

macOS・iOS・watchOS の非公開ヘッダーを生成し、シンボル名を検索する CLI ツールです。
生成元には、この Mac の macOS、インストール済みのシミュレータランタイム、
SSH で接続できる iPhoneOS 環境（脱獄した iPhone や vphone）を使います。

Homebrew での配布・動作確認は、macOS 26 以降の Apple Silicon 搭載 Mac が対象です。
シミュレータからの生成には、Xcode と対応するランタイムも必要です。
SSH での生成には、接続先の SSH サーバーと `tar`、同梱の iPhoneOS helper を実行できる環境が必要です。

## クイックスタート

### インストール

新しくインストールする場合は、[Homebrew](https://brew.sh/) を使います。

```sh
brew install lynnswap/tap/privateheaderkit
```

> [!NOTE]
> 以前のシェルインストーラーや `privateheaderkit-install` を使っていた場合は、
> 次のコマンドを一度実行して Homebrew に移行してください。`brew install` を実行済みでも必要です。
>
> ```sh
> curl -fsSL https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh | sh
> ```
>
> 移行後は実行中のコマンドを起動し直してください。生成済みのヘッダーは保持されます。
> 標準以外の場所にインストールしていた場合は、[移行オプション](Docs/installation.md#custom-installation-directories)を参照してください。

### ヘッダーを生成する

```sh
privateheaderkit
```

起動後は画面の案内に沿って、生成元と対象を選びます。
生成物は `~/PrivateHeaderKit` 以下に保存します。ヘッダーの保存先は実行時の表示で確認できます。

## SSH 経由で生成する

SSH の接続先を設定済みなら、次のコマンドで生成できます。

```sh
privateheaderkit --ssh iphone-se --out ~/PrivateHeaderKit --target SpringBoard,SpringBoardUI
```

OS バージョンとビルド番号は接続先から取得します。
認証と USB 経由の接続は、[SSH の設定・生成手順](Docs/generation.md#iphoneos-over-ssh)を参照してください。

起動中のインストール済みアプリは、bundle identifier を指定して生成します。

```sh
privateheaderkit --ssh iphone-se --app com.example.Sample --out ~/PrivateHeaderKit
```

PID の指定と解析用 Mach-O の保存は、[アプリからの生成手順](Docs/generation.md#running-applications-over-ssh)を参照してください。

## Homebrew 版を更新する

```sh
brew update
brew upgrade lynnswap/tap/privateheaderkit
privateheaderkit --tool-version
```

## 詳しい使い方

以下のガイドは英語です。

- [インストール・削除・ソースからのビルド](Docs/installation.md)
- [ヘッダー生成・シンボル検索・自動実行](Docs/generation.md)
- [関数の逆コンパイル](Docs/decompilation.md)
- [トラブルシューティング](Docs/troubleshooting.md)
- [開発・リリース](CONTRIBUTING.md)

[MIT License](LICENSE)
