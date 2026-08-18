# PrivateHeaderKit

[English](README.md)

この Mac またはインストール済み iOS / watchOS Simulator runtime から、検索可能な
private header を生成します。

macOS 14 以降が必要です。prebuilt release は Apple Silicon 向けです。iOS / watchOS
の header 生成には Xcode と対応するインストール済み Simulator runtime が必要です。
実機は生成元にできません。source install には Swift 6.3 と iOS / watchOS Simulator
SDK を含む Xcode が必要です。

## クイックスタート

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh && sh ./install.sh
```

installer が `Next steps` を表示した場合は、下の command の代わりにその内容を実行します。
表示されなかった場合は:

```bash
privateheaderkit
```

source を選び、全 target または個別の framework、bundle、dylib 名を指定します。
デフォルトでは `~/PrivateHeaderKit` に生成し、実際の出力先を `Headers` として表示します。
生成した header は platform と正確な source ごとに整理されます。たとえば
`generated-headers/iOS/27.0_beta_24A5390f` です。

installer が shell profile を勝手に編集することはありません。

## Source から build

source installer を checkout から build して実行します。

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

installer は同じ checkout から `privateheaderkit` と 3 つの内部 helper を build します。
`install.sh` と同じ `--prefix`、`--bindir` option を指定できます。

## インストールオプション

<details>
<summary>インストール先の変更</summary>

command を `~/bin` にインストールする場合:

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh && sh ./install.sh --bindir ~/bin
```

</details>

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

## ドキュメント

- [インストールと更新（英語）](Docs/installation.md)
- [生成、出力、resume の仕様（英語）](Docs/generation.md)
- [トラブルシューティング（英語）](Docs/troubleshooting.md)
- [開発と release（英語）](CONTRIBUTING.md)

## ライセンス

PrivateHeaderKit は [MIT License](LICENSE) で提供します。
