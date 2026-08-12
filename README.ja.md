# PrivateHeaderKit

[English](README.md)

この Mac またはインストール済み iOS Simulator runtime から、検索可能な private
header を生成します。

macOS 14 以降が必要です。prebuilt release は Apple Silicon 向けです。iOS の header
生成には Xcode とインストール済み iOS Simulator runtime が必要です。source install
には Swift 6.3 と iOS Simulator SDK を含む Xcode が必要です。

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

installer が shell profile を勝手に編集することはありません。

## インストールオプション

<details>
<summary>インストール先の変更と source install</summary>

command を `~/bin` にインストールする場合:

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh && sh ./install.sh --bindir ~/bin
```

checkout から build してインストールする場合:

```bash
git clone https://github.com/lynnswap/PrivateHeaderKit.git
cd PrivateHeaderKit
swift run -c release privateheaderkit-install
```

source install には Swift 6.3 と iOS Simulator SDK を含む Xcode が必要です。

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

全 option は `privateheaderkit --help` で確認できます。例の iOS version はインストール
済み runtime に合わせて変更してください。同じ version に一致する runtime が複数ある
場合は `--build <build>` も指定します。

## 更新

install command を再実行してください。release は検証後にだけ activate されます。
download、build、validation、staging の失敗では以前の cohort が active なまま残り、
activation の失敗では復元を試み、その復元も失敗した場合は明示的に報告します。

## ドキュメント

- [インストールと更新（英語）](Docs/installation.md)
- [生成、出力、resume の仕様（英語）](Docs/generation.md)
- [トラブルシューティング（英語）](Docs/troubleshooting.md)
- [開発と release（英語）](CONTRIBUTING.md)

## ライセンス

PrivateHeaderKit は [MIT License](LICENSE) で提供します。
