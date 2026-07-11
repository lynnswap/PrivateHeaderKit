# PrivateHeaderKit rearchitecture contract (2026-07)

Status: approved  
Design gate: 2026-07-11  
Baseline: `c8ce3eca9eac4e6678ab6b198ceafded0a1bd70b`

この文書を今回の移行における唯一の設計 source of truth とする。実装中に契約変更が必要になった場合は、先にこの文書を更新してからコードを変更する。

## 1. Outcome

PrivateHeaderKit を、単一の user-facing command `privateheaderkit` を中心とする resume-safe な生成ツールとして完成させる。

満たすべき outcome は次のとおり。

1. run、target attempt、artifact ownership、publication intent を単一の durable state owner が管理する。
2. raw dump、cleanup、merge の途中で失敗・cancel・process crash しても、公開中の header tree は部分更新されない。
3. 再起動時に DB と公開 pointer を照合し、未完 publication を決定的に収束させる。
4. subprocess の起動、出力収集、signal、cancellation を `swiftlang/swift-subprocess` ベースの単一 adapter に集約する。
5. installer は public command と 2 helper を同一 version cohort として stage・検証し、単一 pointer switch で更新する。
6. source install と GitHub Release install は同じ cohort/layout contract を使い、build failure や欠損 artifact を stale binary で補わない。

## 2. Compatibility and non-goals

### 維持する契約

- user-facing command は `privateheaderkit` だけとする。
- 引数なしの interactive flow を維持する。
- automation 用の `--platform`、`--version`、`--build`、`--system-root`、`--device`、`--out`、`--target`、`--resume` を維持する。
- destructive semantic reset と legacy migration を明示する `--fresh` を追加し、`--resume` とは相互排他にする。
- default artifact lookup path `<output-base>/<source-label>/` を維持する。この path の実体は managed generation を指す symlink へ変更してよい。
- state/log/staging は header tree の外に置く。
- CLI の単一 `<output-base>` から artifact と `<output-base>/.state` を導出する。外部 library consumer がないため、artifact base と state base を独立指定する package API は削除する。
- target discovery と raw header extraction の意味論は変更しない。

### 意図的に互換を切る契約

- README に consumer story がない `PrivateHeaderKitCore` library product は削除する。Core API は package 内 contract とする。
- rewrite 途中の `manifest.json` / `runs/*/run.json` を resume の source of truth として読み続けない。
- legacy JSON state がある場合、`--resume` は fail fast する。明示 `--fresh` は新しい DB state で開始できるが、現在公開中の artifact を新 generation の publication 完了前に削除しない。
- `<output-base>/<source-label>` が既存の通常 directory である場合、自動推測で symlink 化しない。明示 `--fresh` migration が選ばれたときだけ、同一 volume の initial generation として取り込み、旧 tree 全体を retained backup として残す。切替に失敗した場合は元の directory を保持する。

### Non-goals

- SwiftData の採用。
- Core Data model/context graph の導入。
- DB と arbitrary filesystem を 1 ACID transaction に見せること。
- raw dump algorithm、Mach-O parsing、header rendering の再設計。
- Developer ID signing、notarization、release/tag/publish の実行。
- 旧 user-facing command 名の復活。

## 3. Baseline evidence

現状は 5 product、16 target、Swift 約 17,052 行（Objective-C を含む production source は 10,849 行、test は 6,775 行）で、責務集中が次の file に現れている。

| File | Lines | Evidence |
| --- | ---: | --- |
| `Sources/PrivateHeaderKitCLI/PrivateHeaderKitMain.swift` | 2,196 | manual parser、wizard、composition、result rendering、signal handling が同居 |
| `Sources/PrivateHeaderKitCore/PrivateHeaderGenerationExecutor.swift` | 1,434 | state mutation、raw process、staging、cleanup、commit が同居 |
| `Sources/PrivateHeaderKitRawDumpCore/PrivateHeaderKitRawDumpMain.swift` | 1,419 | raw dump owner。今回の semantic rewrite 対象外 |
| `Sources/PrivateHeaderKitCore/PrivateHeaderGenerationState.swift` | 730 | public JSON schema と state utility が同居 |
| `Sources/PrivateHeaderKitInstall/PrivateHeaderKitInstallMain.swift` | 643 | parse/build/fallback/copy/install が同居 |

確認済みの broken invariant:

- `.fresh` は新しい artifact が用意される前に既存 target ownership を manifest から外す。
- cleanup は publication commit より前に live artifact tree に対して実行される。
- commit は file-by-file recursive move であり、途中失敗すると mixed tree を公開する。
- manifest と run JSON は別々に書かれ、両者を 1 state transition として commit できない。
- process cancellation は child termination completion と domain の `.interrupted` を一貫して結び付けていない。
- installer は build failure 後に stale sibling binary へ fallback し、3 binary を逐次上書きする。
- README が示す consumer は CLI だけだが、Core の state/storage/executor implementation types まで public になっている。
- 既存 tests と削除済み rewrite requirements は unknown file 保存を契約にしているため、legacy output を「追跡外なら削除可能」と推測できない。

追加 baseline:

- explicit public declaration line は Core 275、Tooling 85 に対し、`package` declaration は 0。
- status は `TargetStatus`、`RunTargetStatus`、`PhaseStatus`、`ResumeTargetStatus` の 4 系統 26 case に重複し、CLI はさらに raw `String` へ変換している。
- test は Swift Testing の 26 suite / 194 test（Core 101、CLI 32、RawDump 32、Tooling 15、Install 14）。
- clean worktree で `swift package resolve` 後に実行した baseline `swift test` は 194 test / 26 suite が成功する。既存 checkout の stale SwiftPM workspace cache では trait planning error を再現したため、acceptance は clean resolve 可能性と clean build の両方を確認する。

## 4. Owner map

| Concern | Single owner | Boundary |
| --- | --- | --- |
| CLI parse / interactive navigation | `PrivateHeaderKitCLI` | `ArgumentParser` command value -> validated domain request |
| Generation ordering | `GenerationExecutor` | async run operation; owns no process implementation or durable mutable state |
| Durable semantic state | `GenerationStore` actor | domain methods returning immutable `Sendable` snapshots |
| Cross-process exclusivity | `GenerationLease` | existing `flock` held across recovery, raw dump, publication, and state finalization |
| Artifact version construction/publication | `ArtifactPublisher` | fully managed source root; immutable generation + atomic pointer |
| Raw process capability | `RawDumpRunner` port | Core declares request/result closure; Tooling supplies adapter |
| Loaded shared-cache cohort | `GenerationExecutor.PreparedPlan` | one validated inventory defines discovery, fingerprint, and every raw-dump expected UUID; run revalidates identity before mutation |
| Shared-cache inventory process capability | `SharedCacheInventoryRunner` port | Core declares invocation/data closure; CLI supplies the Tooling adapter |
| Process implementation | `SubprocessRawDumpRunner` / Tooling | `swift-subprocess`; owns child lifecycle and output tail |
| Parent signal lifecycle | CLI composition root | `UnixSignals` -> root task cancellation -> child graceful shutdown -> completion await |
| Install/update layout | `VersionCohortInstaller` | complete cohort staged and verified before `current` switch |
| Release asset contract | `release.json` + release scripts | archive entries, checksum, version, architecture, signature expectations |

次の state は置かない。

- CLI wrapper 内の mirror manifest state。
- JSON と SQLite の二重 source of truth。
- actor 外から呼べる generic `withTransaction`。
- DB transaction を跨いだ subprocess/file I/O。
- fallback binary search が作る第二の install source of truth。

## 5. Target and dependency topology

単一 package を維持し、実在する既存 target boundary を使う。新しい layer 名 target は追加しない。

```text
PrivateHeaderKitCLI (composition root)
  ├─> PrivateHeaderKitCore ──> GRDB, PrivateHeaderKitHelperProtocol
  ├─> PrivateHeaderKitTooling ──> Subprocess
  ├─> UnixSignals
  └─> ArgumentParser

PrivateHeaderKitInstallCLI
  ├─> PrivateHeaderKitInstall ──> PrivateHeaderKitTooling
  ├─> UnixSignals
  └─> ArgumentParser

PrivateHeaderKitRawDumpHelper ──> PrivateHeaderKitRawDumpCore, PrivateHeaderKitHelperProtocol
PrivateHeaderKitSimulatorHelper ──> PrivateHeaderKitRawDumpCore, PrivateHeaderKitHelperProtocol
```

Decisions:

- `PrivateHeaderKitCore` product は削除し、target は package 内 semantic owner として残す。
- manifest は `// swift-tools-version: 6.3` へ上げる。deployment baseline の macOS 14 / iOS 17 は維持する。
- GRDB type は Core target 外へ出さない。
- Core は Tooling を import しない。process port を要求し、CLI が concrete adapter を注入する。
- Subprocess は Tooling の macOS process adapter、UnixSignals は user-facing CLI / installer の composition root だけに置き、simulator helper の iOS build graph へ入れない。
- Installer は public reusable library ではなく package-owned executable concern のままにする。
- raw helper command と shared-cache inventory wire schema は `PrivateHeaderKitHelperProtocol` の単一 target で共有し、Core/RawDump/helper/test target から明示依存する。

採用 dependency:

| Package | Requirement | Product | Use |
| --- | --- | --- | --- |
| `groue/GRDB.swift` | `from: 7.11.1` | `GRDB` | SQLite transaction, migration, query mapping |
| `swiftlang/swift-subprocess` | `exact: 1.0.0-beta.1` | `Subprocess` | child process lifecycle, streaming output, cancellation |
| `swift-server/swift-service-lifecycle` | `from: 2.11.0` | `UnixSignals` | async parent signal sequence only |
| `apple/swift-argument-parser` | `from: 1.8.2` | `ArgumentParser` | CLI and installer option grammar/help |

`swift-subprocess` は beta のため exact pin とする。1.0 final 移行時は cancellation/teardown contract test を再実行して requirement を更新する。

Persistence alternatives:

- `apple/foundationdb` は distributed transactional key-value database であり、cluster process、client library、cluster file を前提とする。SwiftPM で tool-local state に埋め込む database ではないため採用しない。
- Core Data は local transaction と migration を提供できるが、この tool の relational run/target/intent state に managed object graph、model resource、context lifecycle を追加する利点がないため採用しない。
- SQLite C API の直接利用は可能だが、migration bookkeeping、row mapping、transaction error handling を package 内で再実装することになるため採用しない。
- GRDB の `DatabaseQueue` を package-internal actor が完全所有する。これは SwiftData の `@ModelActor` に相当する isolation boundary を SwiftData なしで提供し、filesystem publication は別の durable intent protocol で接続する。

## 6. Package API sketch

Core の入口は package scoped で、CLI の使用コードを基準にする。

```swift
package enum PrivateHeaderGeneration {
    package struct Source: Hashable, Sendable { ... }
    package struct Output: Hashable, Sendable { ... }
    package struct Options: Hashable, Sendable { ... }
    package struct Result: Hashable, Sendable {
        package let runID: RunID
        package let artifactDirectory: URL
        package let stateDatabaseURL: URL
        package let targetCounts: TargetCounts
    }
}

package struct GenerationExecutor: Sendable {
    package typealias RawDumpRunner = @Sendable (RawDumpInvocation) async throws -> RawDumpResult
    package typealias SharedCacheInventoryRunner = @Sendable (SharedCacheInventoryInvocation) async throws -> Data

    package struct PreparedPlan: Sendable { ... }

    package init(
        rawDumpRunner: @escaping RawDumpRunner,
        sharedCacheInventoryRunner: @escaping SharedCacheInventoryRunner,
        ...
    )
    package func prepare(_ plan: Plan) async throws -> PreparedPlan
    package func availableResumeSummary(for preparedPlan: PreparedPlan) async throws -> ResumeSummary?
    package func run(_ preparedPlan: PreparedPlan, progressReporter: ProgressReporter?) async throws -> Result
}

package actor GenerationStore {
    package func recover(using publication: PublicationSnapshot) throws -> RecoveryAction
    package func beginRun(_ plan: RunPlan, at: Date) throws -> RunSnapshot
    package func recordTargetAttempt(_ result: TargetAttemptResult, in runID: RunID) throws
    package func preparePublication(_ intent: PublicationIntent) throws
    package func completePublication(_ generationID: GenerationID, at: Date) throws -> RunSnapshot
    package func markInterrupted(_ runID: RunID, at: Date) throws -> RunSnapshot
}
```

Rules:

- actor の mutable state は `DatabaseQueue` reference と lifecycle だけとする。
- actor method 内の `dbQueue.write` / `read` closure は同期処理だけを行い、`await` を含めない。
- subprocess result と filesystem inspection は immutable `Sendable` value として actor へ渡す。
- shared-cache mode は inventory を一度 decode/validate して `PreparedPlan` に保持する。同じ prepared value を resume summary と run に渡し、interactive resume 選択は cohort/target selection を再生成せず `ResumeBehavior` だけ差し替える。
- run は lease、SQLite、publication mutation より前に inventory を再取得し、prepared cohort の UUID と canonical image-path digest が一致しなければ fail fast する。
- raw dump request は shared-cache enabled と expected cache UUID の組を validated value として保持し、全 target を prepared cohort の UUID に固定する。
- run ID、generation ID、artifact path は raw `String` を混同しない専用 value type にする。
- cancellation は `CancellationError` / `.interrupted` として failure から区別する。
- status は相互排他 enum とし、複数 Bool で表さない。

## 7. Durable state contract

DB path:

```text
<state-base>/<source-label>/generation.sqlite
```

Minimum schema:

- `metadata(toolCompatibilityIdentity)`
- GRDB-managed `grdb_migrations(identifier)` as the only schema-version record
- `runs(id, source identity, plan fingerprint, startedAt, endedAt, status)`
- `runTargets(runID, targetID, status, failureSummary, artifactSet)`
- `targets(targetID, lastSuccessfulRunID, status, artifactSet, updatedAt)`
- `publicationIntents(generationID, runID, previousGenerationID, state, createdAt, completedAt)`
- `runLogs(runID, kind, relativePath)`
- monotonic `runOrdering` / `publicationOrdering` sequences for causal latest-state selection

GRDB migration と `grdb_migrations` が schema version の唯一の owner となる。独自の `metadata.schemaVersion` は置かず、未知の migration identifier は newer schema として fail fast する。JSON file は migration/state decision に使わない。必要な human-readable report を残す場合は DB snapshot から生成する derived artifact とし、読み戻して制御フローを決めない。

Plan fingerprint v2 は length-prefixed component encoding を使い、filesystem-only / loaded-shared-cache mode、inventory schema version、cache UUID、validated・deduplicated・sorted image paths の SHA-256 digest を含める。inventory JSON は helper wire payload に限り、durable state owner にはしない。

`startedAt` / `createdAt` は report 用時刻であり、latest run / intent の因果順序には使わない。DB transaction 内で採番する monotonic sequence が順序の owner となり、wall clock rollback や同一 timestamp でも後から成立した transition を選ぶ。

State transition:

```text
run: running -> completed | partial | failed | interrupted
target attempt: running -> completed | failed | interrupted
publication: prepared -> pointerPublished -> committed
                           \-> aborted
```

`prepared`、target result、run update のように同時に成立すべき行は 1 `dbQueue.write` で更新する。raw dump 中に SQLite transaction を開いたままにしない。

Task cancellation と、process crash 後に由来を確定できない startup recovery は run / active target を `.interrupted` へ収束させる。process 内で捕捉できた非 cancellation の filesystem / persistence failure は、同じ publication intent recovery を使っても `.failed` として記録し、typed infrastructure failure summary を返す。

## 8. Artifact publication contract

Generation は単一 output base の artifact-managed area 配下へ置き、state は同じ base の `.state` 配下へ置く。cross-process lease identity はこの canonical output/source identity に結び付ける。

```text
<artifact-base>/
  <source-label> -> .privateheaderkit/<source-label>/current
  .privateheaderkit/<source-label>/
    current -> generations/<generation-id>
    generations/
      <generation-id>/
        .privateheaderkit-generation.json
        Frameworks/...
        PrivateFrameworks/...
```

Contract:

- `<source-label>` path と generation lifecycle は PrivateHeaderKit が完全管理する。既存 tree の unknown file は opaque content として next generation へ引き継ぎ、owned artifact set に含まれない限り削除・上書きしない。
- generation directory は immutable。publish 後に内容を書き換えない。
- 次 generation は current generation の snapshot から作り、成功 target の owned paths だけを staging 上で置換する。
- `.fresh` でも live tree の cleanup は行わない。成功 target の旧 owned paths は次 generation 上で削除してから新 artifact を置く。
- failed/interrupted target は current generation の last successful artifacts を保持し、attempt failure は DB に別記録する。
- cancel 前に完了した target がある場合は、それらを含む generation の publication を recoverable critical section として完了させてから cancellation を caller へ返す。
- publication atomicity は per-run とする。成功 target をまとめた 1 coherent snapshot を publish し、failed/interrupted target の last successful content は snapshot 内に保持する。成功 target が 0 の run は pointer を切り替えない。
- pointer switch は temporary symlink を同一 parent directory で作成し、atomic rename/replace する。
- current の symlink-to-symlink switch は same-filesystem `rename(2)` を使う。macOS の契約は crash 中も destination 名が存在することを保証する。
- legacy real directory と stable symlink の初回切替は、異なる item type を atomic swap できる `renameatx_np(..., RENAME_SWAP)` を使う。volume が `RENAME_SWAP` を提供しない場合は元 tree を変更せず migration unsupported として fail fast し、逐次 remove/rename fallback を置かない。
- generation marker の ID、artifact set checksum、plan fingerprint を publish 前に検証する。
- artifact ownership は volume semantics に依存させない。各 path component を NFC、`en_US_POSIX` case-insensitive fold、NFC の順で portable key 化し、異なる component spelling、同一 leaf、file/descendant prefix の衝突を target 内・target 間・opaque 間で一括拒否する。同じ spelling の共有 directory prefix は許可する。
- completed target の置換は prospective ownership、全 removal、全 source、全 destination を immutable mutation plan として検証してから draft を変更する。legacy opaque path は incoming path と byte-for-byte 同一の場合だけ target が claim でき、case/Unicode alias は claim とみなさない。
- 同じ portable validator を apply、legacy inventory、generation prepare、persisted marker validation で使い、checksum/inventory mismatch より ownership collision を先に報告する。
- raw staging に `.h` / `.swiftinterface` 以外の regular file、未許可 symlink、hidden payload があれば publish せず fail fast する。inventory と実際の published files を一致させる。
- current/artifact inspection は「存在しない」と permission/path validation/I/O error を区別し、後者を stale artifact に読み替えない。
- snapshot seed は APFS clone を correctness requirement にしない。clone が利用できなければ同一 volume staging へ通常 copy し、完了前の失敗は live pointer に影響させない。

Publication order:

1. cross-process lease を取得し、startup recovery を完了する。
2. DB transaction で `prepared` intent を保存する。
3. complete generation を同一 volume の temporary path から final immutable path へ移す。
4. `current` pointer を atomic switch する。
5. DB transaction で `pointerPublished` と run/target semantic state を確定する。
6. DB transaction で intent を `committed` にし、retention cleanup 候補を確定する。
7. lease 解放前に不要 staging を削除する。cleanup failure は log するが committed generation を rollback しない。

DB と filesystem は 1 ACID transaction ではない。正しさは durable intent、immutable generation、atomic pointer、idempotent recovery の組合せで保証する。

保証範囲は process crash / kill 後の論理 recovery と、reader が old/new の complete tree のどちらかだけを観測する atomic visibility までとする。file/DB の flush 境界は実装するが、hardware/volume が durable rename を保証しない power-loss まで分散 ACID として表明しない。

Generation retention は current、previous committed 1 世代、未完 intent が参照する全世代を必ず保持する。追加の committed generation は新 commit 完了後に最大 3 世代まで GC できる。GC は marker と DB reference の双方を確認し、unknown path、current、prepared、pointerPublished generation を削除しない。

## 9. Startup recovery matrix

Recovery は lease 取得直後、resume/fresh decision より前に必ず実行する。

| DB intent | current pointer | Generation marker | Action |
| --- | --- | --- | --- |
| `prepared` | previous/absent | new complete | intent を `aborted`、new generation を retention cleanup 候補へ |
| `prepared` / `pointerPublished` | new | new complete | DB semantic rowsを roll-forwardし `committed` |
| `committed` | new | new complete | no-op |
| `committed` | previous/absent | any | invariant violation。推測で republish せず fail fast |
| no intent | points to generation | matching complete marker | current generation として認識 |
| no intent | orphan generation | valid non-current marker | retention cleanup 候補 |
| any | malformed/missing marker | malformed | managed state corruption として fail fast |

Recovery/fault-injection tests は各境界（intent 前、generation move 後、pointer switch 後、DB finalize 前）で process crash 相当を再現する。

## 10. Cancellation and subprocess contract

- CLI / installer process lifetime が各 root operation `Task` handle を所有する。
- `UnixSignals` から `SIGINT` / `SIGTERM` を受けたら root task を cancel する。
- Tooling adapter は task cancellation を child process へ伝え、graceful termination を開始する。
- child termination completion と output drain を await してから adapter result/throw を返す。
- Core は cancellation を `.interrupted` として保存し、generic `.failed` に変換しない。
- publication critical section に入った後は durable intent に従って publish/recover 可能な地点まで進める。
- fire-and-forget task、unowned process handle、sleep での completion 推測を置かない。

`ProcessRunner.swift` と `StreamingSubprocess.swift` の Foundation `Process` 実装は、新 adapter への全 call-site 移行後に削除する。legacy wrapper を残さない。

## 11. CLI contract

- `ArgumentParser` が option grammar、validation entry、help、version、exit mapping を所有する。
- interactive wizard は引数なし invocation の application flow として残し、ArgumentParser に UI state を持たせない。
- parser は validated `PrivateHeaderKitGenerateCommand` value を生成し、domain source/output/options への変換は 1 箇所に置く。
- `--fresh` は legacy state/output migration と resume state reset を明示する。interactive flow は対象、backup path、unknown content の保持を表示して確認する。non-interactive migration は `--fresh` がない限り実行しない。
- CLI は DB file/JSON schema を decode しない。`GenerationStore`/`Result` が返す snapshot だけで result screen を描画する。
- `PrivateHeaderKitMain.swift` の parse、wizard、render、composition は責務ごとの file へ分割するが、新 target は作らない。

## 12. Installer and release contract

Installed layout:

```text
<prefix>/libexec/privateheaderkit/
  versions/<version+cohort-sha>/
    privateheaderkit
    privateheaderkit-raw-helper
    privateheaderkit-sim-helper
    release.json
  current -> versions/<version+cohort-sha>

<prefix>/bin/privateheaderkit -> ../libexec/privateheaderkit/current/privateheaderkit
```

Install sequence:

1. `prefix` / `binDir` の既存 ancestor と symlink alias を canonicalize し、その identity から全 managed path と install lock を一度だけ導出する。
2. install lock を取得し、未完の direct-layout migration intent があれば filesystem の実状態と complete cohort を検証して idempotent に roll-forward / rollback する。
3. 全 source artifact を build/resolve する。1 つでも失敗・欠損なら既存 install を変更せず終了する。
4. temporary cohort directory に 3 binary と `release.json` を stage する。
5. version、SHA-256、architecture/platform、executable permission、code signature policy を全 artifact で検証する。
6. immutable `versions/<cohort>` へ exclusive publish する。destination が既にある場合だけ、その complete manifest/content を検証して再利用する。
7. direct-layout migration では legacy file identity と同一 parent の public-command backup を durable intent に保存する。
8. `current` symlink を atomic switch する。
9. stable `<prefix>/bin/privateheaderkit` symlink を作成/検証する。
10. old direct-layout helper/binary は snapshot identity が一致し、new cohort が active と確認できた後だけ削除する。不一致や post-commit cleanup failure は warning とし、unknown file を削除しない。

Source install と release install は同じ layout/manifest semantics を使う。build failure を warning にして sibling/base URL の stale binary へ fallback しない。

Source install は build 前の `HEAD`、release tag/effective provenance、tracked diff、untracked input content を 1 source snapshot として fingerprint し、全 product build 後に同一性を再検証する。dirty checkout は許可するが、build 中に source snapshot が変化した cohort は install しない。

Direct-layout migration は DB と filesystem を跨ぐ小さな transaction として扱う。intent write、complete cohort、atomic pointer、same-parent backup を recovery evidence とし、process kill 後の mixed direct/managed layout を単なる ambiguity として拒否せず、lock 取得直後に old complete layout または new complete cohort へ収束させる。intent 自体が malformed、またはどちらの complete state も証明できない場合だけ fail fast する。

`cohort-sha` は git commit ではなく、sorted artifact name / SHA-256 / platform / architecture から算出する content identity とする。git commit は `release.json` の provenance metadata に別記録する。同じ HEAD でも debug/release、build setting、dirty source が異なる binary set を同じ immutable directory と誤認しない。

同一 version / cohort identity の directory が既に存在しても、`release.json` の commit provenance が install request と異なる場合は暗黙再利用しない。既存 manifest の書換え、first-wins、provenance の読み替えは immutable cohort の意味を壊すため、provenance collision として fail fast する。release workflow は同一 version の tag target 不一致を build 前に拒否する。

tag のない source install は固定 `0.0.0-dev` を共有せず、`0.0.0-dev.<short-commit>` を version identity とする。docs-only change や最適化で binary bytes が同じになった別 commit も異なる source snapshot として配置し、上記 provenance collision を通常の source update path にしない。

Release pipeline は次を追加する。

- `scripts/build-release.sh`
- `scripts/package-release.sh`
- `scripts/install-release.sh.in`
- `scripts/verify-release-assets.sh`
- `.github/workflows/release.yml`

Release asset set は archive、`SHA256SUMS.txt`、version を焼き込んだ `install.sh` の exact set とする。workflow は default branch HEAD、tag target、digest、draft state を検証し、publish は手動 gate とする。今回 push/tag/release は行わない。

## 13. Deletion and consolidation list

移行完了条件として、次を削除または owner へ統合する。

- `PrivateHeaderGenerationRunRepository.swift` の manifest/run JSON state owner。
- `PrivateHeaderGenerationState.swift` の `StateJSON` と public persistence schema surface。
- live artifact tree を変更する `ArtifactStore.cleanupManagedArtifacts`。
- file-by-file `mergeDirectoryContents` commit。
- Core の `GenerationExecutor.liveRawDumpRunner` と `RawDumpOutputCapture`。
- Tooling の重複 Foundation `Process` implementations。
- manual CLI/installer option parser と duplicate help grammar。
- installer の build-warning fallback と 3 binary sequential overwrite。
- README に consumer story のない `PrivateHeaderKitCore` product。
- source/test tree の `.DS_Store`。

旧実装を包む `LegacyStoreAdapter`、JSON mirror、dual-write、fallback read は追加しない。

## 14. Implementation workstreams

### A. Durable generation + artifact publication

Write set: `PrivateHeaderKitCore`, Core tests, Core dependency wiring.

- GRDB schema/migrations and actor.
- domain snapshots/status transitions.
- immutable generation builder/publisher/recovery.
- executor migration and removal of JSON/live merge owners.
- deterministic crash/cancellation/resume tests.

### B. Process + CLI composition

Write set: `PrivateHeaderKitTooling`, `PrivateHeaderKitCLI`, related tests, package dependency wiring after A integration.

- `swift-subprocess` adapter.
- Unix signal root-task ownership.
- ArgumentParser grammar and interactive flow composition.
- Core live process removal and cancellation mapping.

### C. Installer + release assets

Write set: `PrivateHeaderKitInstall*`, install tests, `scripts`, `.github/workflows`, README install sections.

- version cohort installer and migration from direct layout.
- fail-fast source build.
- manifest/checksum/release script generation and exact verifier.
- workflow security pinning and draft release gate.

Workstreams A/B overlap in composition and therefore integrate sequentially. C may proceed in parallel because it does not edit Core/CLI generation files. `Package.swift` is integrated by the main owner to avoid dependency graph conflicts.

## 15. Verification gate

Required before completion:

1. `swift test` on the integrated package.
2. focused GenerationStore migration/transaction tests with temporary DB.
3. publication fault matrix, including simulated crash after pointer switch and before DB finalize.
4. fresh/resume/partial/failure/cancellation tests proving live current output remains coherent.
5. subprocess normal/failure/signal/cancellation/output-drain tests without wall-clock sleeps.
6. parser/help/version/interactive routing tests.
7. installer missing artifact, Nth-step fault, existing cohort rollback, concurrent install, and direct-layout migration tests.
8. release asset exact-set/checksum/tamper verification in a temporary prefix.
9. `swift build -c release --product privateheaderkit` and installer product build.
10. simulator helper product build for its intended destination/triple where the local environment supports it; otherwise record the exact observability gap.
11. `git diff --check`.
12. `codex-review` after repo-local checks, with findings fixed and review rerun until clean.
13. `PrivateHeaderKitCore` target と Core tests の iOS simulator compile gate。Core library product は復活させない。

## 16. Findings-to-tests mapping

| Finding | Owner fix | Regression proof |
| --- | --- | --- |
| fresh drops ownership before work | staged generation + DB attempt separation | fresh failure preserves old current and target ownership |
| cleanup mutates live tree | cleanup only inside unpublished generation | injected cleanup/raw failure leaves current tree byte-identical |
| recursive merge exposes partial tree | one pointer publication | injected failure at each publication boundary yields old or complete new tree |
| split JSON writes drift | one GRDB transaction per semantic transition | injected throw rolls back all related rows |
| crash after pointer switch | startup recovery roll-forward | reopen store/publisher commits matching intent |
| cancellation becomes failure | root task + child lifecycle + interrupted state | signal/cancel test observes child completion and `.interrupted` |
| stale installer fallback | preflight all artifacts, then cohort switch | build/missing helper failure leaves current cohort unchanged |
| mixed-version direct copies | immutable cohort + current pointer | Nth-step failure reports old cohort for all three binaries |
| accidental public implementation API | package scope + product removal | package describe has no Core library product; CLI/tests still compile |
| discovery and raw dump observe different loaded caches | prepared cohort + pre-mutation identity revalidation + expected UUID | summary reuses one prepared value; changed UUID/path digest fails before state/output mutation; every raw invocation carries one UUID |
| cache-only `/usr/lib` images are undiscoverable | filesystem/cache inventory union in `TargetDiscovery` | duplicate cache/filesystem paths deduplicate and cache-only direct dylibs resolve |
| portable artifact aliases overwrite or hide ownership | `ArtifactPublisher` prospective ownership trie + preflighted mutation plan | case/NFC/prefix/same-target/opaque/forged-marker collisions fail before mutation; exact opaque claim and identical shared directories succeed |
