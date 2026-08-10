# PrivateHeaderKit

[English](README.md)

iOS / macOS の private framework ヘッダを生成します。

- iOS: Simulator ランタイムと dyld shared cache から生成
- macOS: ホストの `/System/Library/{Frameworks,PrivateFrameworks}` から生成

## コマンド構成

PrivateHeaderKit がユーザー向けに公開するコマンドは 1 つです。

```bash
privateheaderkit
```

旧 `privateheaderkit-dump` / `headerdump` / `headerdump-sim` は
user-facing command としてインストールしません。低レベルの raw dump は、公開
コマンドと同じ cohort としてインストール・更新される internal helper が扱います。

## インストール

Apple Silicon Mac では、version を焼き込んだ installer から最新の検証済み
release cohort をインストールできます。

```bash
curl -fsSLO https://github.com/lynnswap/PrivateHeaderKit/releases/latest/download/install.sh
sh install.sh
```

各 release の downloadable asset は、次の 3 ファイルだけです。

- `install.sh`
- `SHA256SUMS.txt`
- `privateheaderkit-darwin-arm64.tar.gz`

version-baked installer は対応する archive と checksum file を取得し、archive の
checksum と内容の完全一致を確認します。続いて `release.json` と 3 executable
すべてについて、SHA-256、architecture、platform、実行権限、code signature を
検証します。cohort 全体が検証を通った後にだけ immutable cohort を publish し、
active な `current` link を切り替えます。デフォルトの stable user-facing command
は `~/.local/bin/privateheaderkit` です。

`~/.local/bin` が `PATH` に入っていない場合は追加してください。

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
  current -> versions/<version>+<cohort-sha256>
  versions/<version>+<cohort-sha256>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    release.json
```

public command は `privateheaderkit` だけです。2 つの helper は常に同じ検証済み
cohort から解決されます。更新時は最新の `install.sh` を再取得して実行するか、
source checkout を更新して `swift run -c release privateheaderkit-install` を再実行
します。build、download、validation、staging のいずれかが失敗した場合は、以前の
検証済み cohort が active なまま維持されます。activation に失敗した場合、installer
は以前の cohort の復元を試み、rollback 自体の失敗も隠さず報告します。tag のない
source checkout は commit を含む `0.0.0-dev.<short-commit>` version namespace を使います。

3 つの executable file を直接置く旧 install は、installer lock の下で移行します。
移行が中断された場合は、次回の install で記録済み migration intent から復旧します。
一部欠損または曖昧な legacy layout は拒否し、intent の記録後に file が変化していた
場合も推測で復旧しません。内容が変わった retired helper は削除せず残しますが、検証
済みの `current` と public command の link が managed layout を確定した後は、その
leftover が後続の managed install を妨げることはありません。

maintainer は `Prepare Draft Release` workflow で release を準備します。workflow は
version と、現在の default branch HEAD の full SHA を指定して dispatch する必要が
あります。workflow は、上記 3 asset だけを持つ draft GitHub Release を作成または
修復します。draft と release note の確認後に手動で publish します。

## 生成

```bash
privateheaderkit
privateheaderkit --help
```

`privateheaderkit` を引数なしで実行すると interactive generation wizard を開始し、
デフォルトの output base として `~/PrivateHeaderKit` を使います。互換性のある未完了
state があれば `Continue` / `Restart` の明示選択を求め、legacy state または output
を移行する前にも確認を求めます。両方が存在する場合は、同じ確認画面に双方の path と
保存または backup の扱いを表示してから移行します。automation / CI では generation
option を直接渡します。

```bash
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
privateheaderkit --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --device "iPhone 17" --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit" --fresh
privateheaderkit --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
```

iOS 生成では、`privateheaderkit` が `--version` / `--build` から利用可能な Simulator
runtime を解決し、device を選択・boot して internal simulator helper を使います。
`--system-root` は iOS では任意です。指定した場合はその runtime root を使い、解決
した runtime path で置き換えません。`--device <name-or-udid>` と
`--sim-helper <path>` は automation 用の任意 flag です。

`--target` は comma-separated target query であり、stable target ID list では
ありません。`--resume` と `--fresh` は同時に指定できません。

- `--resume` は最新の互換 plan を継続し、未完了または欠損している target を実行
  します。plan fingerprint が変わった場合や、選択 target が以前より減った場合は
  incompatible として拒否します。
- `--fresh` は選択した全 target について新しい run を開始します。legacy JSON state
  と legacy output directory の明示的な移行も許可します。
- どちらも指定しない場合、過去の state がなければ新しい run を開始します。未完了
  work がない互換 state は再利用できますが、未完了 state がある場合は、呼び出し側
  が `--resume` または `--fresh` を明示するまで拒否します。

`--fresh` は処理開始前に現在 publish 済みの header tree を削除しません。publish は
毎回、新しい immutable generation として構築します。完了した target は自身が所有
する file だけを置き換え、失敗または中断した target には最後に publish 成功した
file を残します。旧 `<version>` positional style は public surface に含みません。

## Output Layout Contract

output base には、stable な source storage ID path、immutable generation、source
ごとの SQLite state database を配置します。

```text
<output-base>/
  <source-storage-id> -> .privateheaderkit/<source-storage-id>/current
  .privateheaderkit/
    <source-storage-id>/
      current -> generations/<generation-id>
      generations/
        <generation-id>/
          .privateheaderkit-generation.json
          Frameworks/...
          PrivateFrameworks/...
      legacy-backups/...
  .state/
    <source-storage-id>/
      generation.sqlite
```

`--out` は `<output-base>` を指定します。consumer は
`<output-base>/<source-storage-id>/` を使い、publication metadata と immutable
generation directory は `.privateheaderkit` 以下に置きます。`legacy-backups` は
rewrite 前の output directory を移行した場合にだけ作成します。generation state、
target attempt、publication intent、run log は `generation.sqlite` に保存します。
storage ID は PrivateHeaderKit が所有する versioned identifier であり、consumer は
表示用 source label から組み立てません。

## Legacy Output の移行

旧 `.state/<source-storage-id>/manifest.json` と `runs/` の data は resumable state として
import しません。`generation.sqlite` がなく、これらの path が存在する場合、
`--fresh` なしの run は停止します。明示的な fresh migration は
`generation.sqlite` を作成し、旧 JSON path はそのまま残します。

実 directory として存在する `<output-base>/<source-storage-id>/` は黙って取り込みません。
`--fresh` を指定すると、PrivateHeaderKit はその通常 file を inventory して draft
generation にコピーし、owner のない opaque file として記録します。その後、directory
と symlink を atomic swap して managed stable path を publish し、元の directory を
`.privateheaderkit/<source-storage-id>/legacy-backups/` 以下に保持します。legacy tree を検証
できない場合や filesystem が atomic swap を実行できない場合は、元の output path を
置き換えずに migration を失敗させます。

## メモ

- iOS runtime discovery と simulator execution には、`xcrun`、`simctl`、および
  iPhone Simulator SDK がインストールされた Xcode が必要です。
- source からの build または install には、追加で Swift 6.3 toolchain が必要です。
- state、log、staging data は publish 済み generated header tree の外に置きます。

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
