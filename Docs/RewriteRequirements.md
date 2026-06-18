# PrivateHeaderKit Rewrite Requirements

この文書は PrivateHeaderKit を破壊的変更前提で作り直すための要件を固定する。既存 CLI/API 互換より、実行の再現性、resume 可能性、最大情報取得、CI/自動化との相性を優先する。

## Goals

- ユーザーが直接使うコマンド成果物は 1 つにする。
- iOS simulator runtime から取得できる情報量を最大化するため、内部 helper は維持する。
- interactive wizard は first-class にする。ただし CI/自動化では interactive を要求しない。
- dump artifact と管理情報を分離し、通常の `rg` で state/log/manifest が混ざらないようにする。
- 中断、失敗、partial 成果物を明示的に管理し、build/source 単位で安全に resume できるようにする。
- SwiftUI/ObservationBridge 風に、公開 API は薄い top-level entry と namespace 型に整理する。

## Non-Goals

- 旧 CLI option の完全互換は目標にしない。
- `quality` のような情報量を落とす mode は持たない。常に最大取得を試みる。
- ユーザーに安定 ID や内部 target identity を指定させない。
- `SystemLibrary` や `/usr/lib dylib` などの内部分類を通常 UI の選択肢として見せない。

## Public Surface

### Command

- 公開する user-facing executable product は 1 つにする。
- 推奨名は `privateheaderkit`。
- 旧 `privateheaderkit-dump` / `headerdump` / `headerdump-sim` は公開 surface から外す。
- simulator 内で動く helper は内部実装として維持する。最大情報取得のため、runtime Objective-C fallback などを担当する。

Breaking changes from current CLI:

- 現行の複数 executable product は 1 つへ統合する。
- 現行の `privateheaderkit-dump <version>` style は廃止し、source selection は explicit option または wizard で扱う。
- `--list-runtimes`, `--list-devices`, `--json`, `--platform`, `--out`, `--target` は新 CLI surface として再設計する。
- legacy `--framework`, `--filter`, `--scope` は互換維持を目的に残さない。必要なら migration note だけ書く。
- 旧 default scope の Frameworks/PrivateFrameworks only から、新しい `すべて` は SystemLibrary bundles、`/usr/lib` dylibs、nested bundles まで含む。

### Swift API Shape

ObservationBridge のように、公開 API は小さく保つ。

- top-level function: `generatePrivateHeaders(...)`
- namespace 型: `PrivateHeaderGeneration`
- nested types: `PrivateHeaderGeneration.Options`, `PrivateHeaderGeneration.Result`, `PrivateHeaderGeneration.Target`, `PrivateHeaderGeneration.Source`
- long-running operation を公開する必要がある場合は `PrivateHeaderGeneration.Token` を使い、`cancel()` を持たせる。
- 内部 target は `_PrivateHeaderKit...` prefix で隠す。

## Source Identity

Source は resume と出力ディレクトリの単位になる。

- 表示名: `iOS 27.0 (24A5355q)`
- ディレクトリ名: `iOS27.0(24A5355q)`
- macOS も同じ規則にする: `macOS26.5(25F...)`
- iOS runtime の version/build は `xcrun simctl list runtimes -j` の `version` と `buildversion` を使う。
- 同じ iOS version でも build が違えば別 source として扱う。

## Output Layout

default:

```text
~/PrivateHeaderKit/
  generated-headers/
    iOS27.0(24A5355q)/
      ...
  .state/
    iOS27.0(24A5355q)/
      manifest.json
      runs/
        <run-id>/
          run.json
          logs/
          staging/
```

custom output base:

```text
/Volumes/Data/Headers/
  iOS27.0(24A5355q)/
    ...
  .state/
    iOS27.0(24A5355q)/
      manifest.json
      runs/
```

Rules:

- `--out` and `PH_OUT_DIR` は artifact root ではなく output base directory として扱う。
- artifact は常に `<artifact-base>/<source-label>/` に置く。
- default の artifact base は `~/PrivateHeaderKit/generated-headers`、state base は `~/PrivateHeaderKit/.state` とする。
- custom output の場合は、artifact base と state base を同じ指定 directory の下に置く。artifact は `<output-base>/<source-label>/`、state は `<output-base>/.state/<source-label>/`。
- state/log/staging は artifact tree の中に置かない。

## Interactive Flow

Command with no non-interactive target enters wizard.

1. Source selection
   - available runtimes を表示する。
   - `iOS 27.0 (24A5355q)` のように space ありで表示する。
   - Enter default は持たない。空入力は `入力してください` として再入力。
2. Target selection
   - `[1] すべて`
   - `[2] 個別に選ぶ`
   - `[3] キャンセル`
3. Individual target input
   - comma-separated text input。
   - partial match を許可する。
   - no match は候補なしとして再入力。
   - ambiguous match は候補一覧を出し、番号入力で解決する。
   - 複数候補を選べる。`all` 相当も許可する。
4. Output plan
   - source, output path, selected target count を表示する。
5. Existing state/output check
   - unfinished compatible run があれば resume screen を出す。
   - unfinished run がなく、既存 completed artifact があれば existing output screen を出す。
6. Final confirmation
   - `すべて` の場合は target count と output path を出して開始確認する。
   - destructive rebuild の場合は削除対象 target 数を出して明示確認する。
7. Run progress
   - current target と phase を表示する。
   - phase examples: `static ObjC`, `runtime ObjC`, `Swift interface`, `nested bundles`, `commit`
8. Summary
   - output path
   - `Completed`, `Partial`, `Failed`, `Skipped`
   - first 20 failures
   - manifest path

Keyboard behavior:

- `Esc` は 1 screen 戻る。
- first screen での `Esc` は cancel。
- 戻った場合も入力済み state は保持する。
- `Ctrl-C` before run は exit。
- `Ctrl-C` during run は current target を `interrupted` として記録し、次回 resume で target 全体を再実行する。

## Target Semantics

- `すべて` は内部的に current `@all` 相当を意味する。
- 対象には Frameworks、PrivateFrameworks、SystemLibrary bundles、`/usr/lib` dylibs、nested bundles を含める。
- ユーザー向け UI では分類を選ばせず、必要なら summary として件数だけ表示する。
- target identity は内部で安定化するが、ユーザーには名前/partial match で入力させる。

## Non-Interactive Behavior

- CI/script では interactive prompt を出さない。
- unfinished compatible run がある場合は error にし、明示的な `--resume` を要求する。
- `--resume` は compatible run の incomplete targets を再実行する。
- `--fresh` またはそれに相当する explicit option は、選択 target の既存 managed artifacts を消して再作成する。
- destructive option は non-interactive でも明示されている場合だけ実行する。
- failures/partials があれば exit code は non-zero。

## Resume Rules

Resume は source label/build 単位で管理する。

Compatible run の条件:

- same source label
- same output base
- same selected target set
- same layout
- manifest schema が読み取れる

Not compatible:

- runtime build が違う
- selected target set が違う
- layout が違う
- manifest schema がサポート外

Unfinished compatible run screen:

```text
前回の実行が途中で終了しています。

Source: iOS 27.0 (24A5355q)
Output: ~/PrivateHeaderKit/generated-headers/iOS27.0(24A5355q)
Targets: all (1842)
Started: 2026-06-18 12:25:10
Updated: 2026-06-18 13:14:02
Completed: 1310, Partial: 4, Failed: 12, Pending: 516

[1] 続きから実行
[2] 最初から実行
[3] キャンセル
```

Rules:

- completed target は resume で skip する。
- failed target は resume で retry する。
- partial target は target 全体を再実行する。
- interrupted target は target 全体を再実行する。
- commitFailed target は cleanup して target 全体を再実行する。
- 「最初から実行」は selected target の managed artifacts と previous staging/log を片付けてから開始する。

Existing completed output screen:

```text
既存の出力があります。

Source: iOS 27.0 (24A5355q)
Output: ~/PrivateHeaderKit/generated-headers/iOS27.0(24A5355q)
Completed: 1842, Partial: 0, Failed: 0

[1] 不足分だけ実行
[2] 最初から作り直す
[3] キャンセル
```

Rules:

- all complete なら `[1]` は no-op summary を出して終了する。
- `[2]` は selected targets の managed artifacts だけを削除する。
- unknown user files は削除しない。

## State Files

### `manifest.json`

Pretty JSON で書く。source label 単位の latest state を表す。

Required fields:

- `schemaVersion`
- `toolVersion`
- `source`
  - `platform`
  - `version`
  - `build`
  - `displayName`
  - `directoryName`
- `output`
  - `baseDirectory`
  - `artifactDirectory`
  - `stateDirectory`
- `layout`
- `latestRunID`
- `targets`
- `updatedAt`

Each target entry:

- `id`
- `displayName`
- `kind`
- `status`
- `phases`
- `artifacts`
- `lastRunID`
- `updatedAt`
- `failureSummary`

Artifacts:

- all generated `.h` and `.swiftinterface` relative paths are stored.
- `completed` 判定は manifest entry だけで行わない。manifest-managed artifact の実体が存在し、少なくとも期待される `.h` または `.swiftinterface` があることを確認する。
- cleanup/recreate only deletes manifest-managed paths.
- unknown files are preserved.
- after deleting files, empty parent directories are removed up to artifact root.

### `run.json`

Run 単位の immutable-ish record として扱う。

Required fields:

- `runID`
- `schemaVersion`
- `toolVersion`
- `plan`
- `startedAt`
- `endedAt`
- `status`
- `targetResults`
- `attemptedArtifacts`
- `logs`

Rules:

- `runs/<run-id>/staging/` に生成してから commit する。
- runtime root や `/System/Cryptexes` から staging へ出た artifact は、現行の relocation/rebase semantics を維持して final artifact path へ正規化する。
- run history は latest 10 件だけ保持する。
- old run cleanup は command startup で行う。
- old run cleanup は `runs/<old-run-id>/` の logs/staging/run.json を削除する。
- latest target state は `manifest.json` に残す。

## Target Status

Manifest target statuses:

- `completed`
- `partial`
- `failed`
- `interrupted`
- `commitFailed`
- `stale`

Run-local statuses:

- `pending`
- `running`
- `skipped`
- `completed`
- `partial`
- `failed`
- `interrupted`
- `commitFailed`

Phase statuses:

- `pending`
- `running`
- `completed`
- `failed`
- `skipped`

Partial definition:

- target の一部 artifact は生成できたが、required phase の一部が失敗した状態。
- `Swift interface` 失敗も partial として扱う。
- nested bundle の失敗は親 target を無条件に completed にしない。親 target は `partial` または `failed` として扱い、resume で target 全体を再実行する。
- partial は success ではないため exit code は non-zero。

## Commit Transaction

Per target:

1. cleanup stale staging for target/run
2. generate into `runs/<run-id>/staging/<target-id>/`
3. collect attempted artifacts
4. if generation failed before commit, keep old final artifacts untouched
5. if generation succeeded, delete old manifest-managed final artifacts for target
6. move/copy staging artifacts into final artifact directory
7. write manifest target entry

Commit failure:

- target status becomes `commitFailed`
- `run.json` records attempted final artifact paths
- next resume cleans manifest-managed artifacts plus attempted paths before re-running target

## Error Handling

- Per-target failure is recorded and execution continues.
- Summary shows first 20 failures.
- Full failure details live in `run.json` and logs.
- Any `failed`, `partial`, `interrupted`, or `commitFailed` result makes exit code non-zero.
- No silent success with missing Swift interface when Swift extraction was expected.

## Simulator Execution

- helper は internal implementation detail として扱うが、runtime Objective-C fallback のため simulator process で実行できる状態を維持する。
- resume state には、source identity だけでなく、実行に使った simulator runtime/device/clone policy/execution mode を記録する。
- 再開時に同じ device が使えない場合は、source identity と plan compatibility を保ったまま代替 device を選び、run record に記録する。
- `SIMCTL_CHILD_*` を含む helper 実行 environment は plan/run に残し、再現性を確保する。
- simulator helper が実行できない場合の host fallback は、target result に fallback として記録する。fallback により情報量が落ちる場合は `partial` または warning として summary に出す。

## Layout and Migration

- 新 rewrite の primary layout は 1 つに寄せる。
- 旧 `headers` / `bundle` layout のどちらを継続するかは implementation PR の初期 contract で固定する。
- 旧 artifact tree の自動移行は必須にしない。
- 既存 artifact が新 manifest で管理されていない場合は unknown file として扱い、destructive rebuild でも削除しない。
- 旧 output path `~/PrivateHeaderKit/generated-headers/iOS/<version>` は新 source label path と別物として扱う。必要なら README に migration note を書く。

## Implementation Split

Initial worker PRs should avoid overlapping write ownership.

0. Ownership boundary PR
   - owner: `Package.swift`, new target skeletons, initial test file split
   - goal: reduce conflicts before parallel implementation
1. Requirements/docs baseline
   - owner: `Docs/RewriteRequirements.md`, README follow-up notes only
2. Core API and plan contracts
   - owner: new `Sources/PrivateHeaderKitCore/*`, contract tests
   - includes: `PrivateHeaderGeneration`, source identity, target identity, dump plan
3. State model and persistence
   - owner: new state module/files, manifest/run JSON tests
4. Source/runtime discovery and label formatting
   - owner: simctl parsing, source identity tests
5. Target discovery and resolver
   - owner: target model, `all`, comma input resolver, ambiguity tests
6. Transactional executor
   - owner: staging/commit/cleanup, status transitions
7. Interactive wizard
   - owner: prompt screens, Esc navigation, input retention
8. CLI integration
   - owner: public command, non-interactive flags, exit codes
9. Header extraction/helper integration
   - owner: internal host/simulator helper boundary
10. Install/docs compatibility
   - owner: install command/docs after behavior is stable

Shared-file rules:

- `Package.swift` is owned by the ownership boundary PR first; later worker PRs should avoid touching it unless explicitly assigned.
- `Sources/PrivateHeaderKitDump/PrivateHeaderKitDumpMain.swift` is the largest conflict source. Extract pure types/functions into new modules early, then leave a thin facade until final integration.
- `Tests/PrivateHeaderKitDumpTests/PrivateHeaderKitDumpTests.swift` should be split by responsibility early: selection, state, layout, simulator/process.
- `Package.resolved` is currently dirty before this rewrite work. No worker should touch it unless dependency work is explicitly assigned.

## Testing Contracts

Priority tests:

- source label formatting: display vs directory name
- default/custom output layout
- `.state` separation from artifact tree
- pretty JSON manifest
- completed resume skips target
- failed/partial/interrupted resume reruns target
- target set/layout/source mismatch rejects resume
- old run cleanup keeps latest 10
- managed artifact cleanup preserves unknown files
- generation failure before commit keeps old artifacts
- commit failure records attempted artifacts
- interactive empty Enter re-prompts
- interactive Esc goes back and preserves input
- comma-separated target resolution
- ambiguous partial match resolution
- non-interactive unfinished run requires explicit `--resume`

## Documentation Updates

After implementation:

- update `README.md` / `README.ja.md` for the new single command
- document output/state layout
- document resume/new/rebuild behavior
- document non-interactive CI usage
- remove old `headerdump` / `headerdump-sim` as user-facing commands from README
