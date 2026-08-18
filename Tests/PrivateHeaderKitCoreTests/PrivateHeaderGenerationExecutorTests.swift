import Foundation
import GRDB
import PrivateHeaderKitHelperProtocol
import Testing

@testable import PrivateHeaderKitCore

private enum ExecutorFixtureError: Error {
  case unexpectedSharedCacheInventory
}

@Suite
struct PrivateHeaderGenerationExecutorTests {
  private enum InjectedFault: Error {
    case stop
    case rawFailure
  }

  @Test func preparedCacheCohortIsReusedByResumeAndValidatedBeforeEveryRawDump() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let inventoryRunner = RecordingInventoryRunner(
      data: try sharedCacheInventoryData(
        cacheUUID: cacheUUID,
        imagePaths: [
          "/System/Library/Frameworks/Foo.framework/Foo",
          "/System/Library/Frameworks/Bar.framework/Bar",
        ]
      )
    )
    let rawRunner = RecordingRunner(contents: "generated")
    let executor = fixture.executor(
      runner: rawRunner,
      inventoryRunner: { invocation in try await inventoryRunner.run(invocation) },
      runID: "run-cache",
      generationID: "generation-cache"
    )
    let plan = try fixture.plan(
      .identifiers(["framework:Foo.framework", "framework:Bar.framework"]),
      rawDumpingOptions: .init(useSharedCache: true)
    )

    let preparedPlan = try await executor.prepare(plan)
    #expect(preparedPlan.sharedCacheCohort?.cacheUUID == cacheUUID)
    #expect(await inventoryRunner.invocationCount == 1)
    #expect(try await executor.availableResumeSummary(for: preparedPlan) == nil)
    #expect(await inventoryRunner.invocationCount == 1)
    _ = try await executor.run(preparedPlan)

    #expect(await inventoryRunner.invocationCount == 2)
    #expect(await rawRunner.invocationCount == 2)
    for invocation in await rawRunner.invocations {
      #expect(invocation.command.contains("--expected-cache-uuid"))
      #expect(invocation.command.contains(cacheUUID.uuidString.lowercased()))
    }
  }

  @Test func disabledSharedCacheDoesNotInvokeInventoryRunner() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let inventoryRunner = RecordingInventoryRunner(
      data: try sharedCacheInventoryData(
        imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
      )
    )
    let executor = fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      inventoryRunner: { invocation in try await inventoryRunner.run(invocation) },
      runID: "run-no-cache",
      generationID: "generation-no-cache"
    )

    let preparedPlan = try await executor.prepare(try fixture.plan(.query("Foo")))
    _ = try await executor.run(preparedPlan)

    #expect(await inventoryRunner.invocationCount == 0)
    #expect(preparedPlan.sharedCacheCohort == nil)
  }

  @Test func changedPreparedCacheCohortFailsBeforeLeaseStateOrRawDump() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let inventoryRunner = RecordingInventoryRunner(
      data: try sharedCacheInventoryData(
        cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
      )
    )
    let rawRunner = RecordingRunner(contents: "generated")
    let executor = fixture.executor(
      runner: rawRunner,
      inventoryRunner: { invocation in try await inventoryRunner.run(invocation) },
      runID: "run-cache-change",
      generationID: "generation-cache-change"
    )
    let preparedPlan = try await executor.prepare(
      try fixture.plan(
        .query("Foo"),
        rawDumpingOptions: .init(useSharedCache: true)
      )
    )
    await inventoryRunner.replaceData(
      try sharedCacheInventoryData(
        cacheUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
        imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
      )
    )

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await executor.run(preparedPlan)
    }

    #expect(await rawRunner.invocationCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.outputBase.path))
  }

  @Test func preparedPlanCanChangeOnlyInteractiveResumeBehaviorWithoutReloadingCohort() async throws
  {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let inventoryRunner = RecordingInventoryRunner(
      data: try sharedCacheInventoryData(
        imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
      )
    )
    let executor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { invocation in try await inventoryRunner.run(invocation) },
      runID: "run-unused",
      generationID: "generation-unused"
    )
    let preparedPlan = try await executor.prepare(
      try fixture.plan(
        .query("Foo"),
        rawDumpingOptions: .init(useSharedCache: true)
      )
    )

    let resumedPlan = preparedPlan.withResumeBehavior(.resume)

    #expect(resumedPlan.plan.options.resumeBehavior == .resume)
    #expect(resumedPlan.sharedCacheCohort == preparedPlan.sharedCacheCohort)
    #expect(resumedPlan.selectedTargetIDs == preparedPlan.selectedTargetIDs)
    #expect(await inventoryRunner.invocationCount == 1)
  }

  @Test func sharedCacheFingerprintIncludesUUIDAndCanonicalInventoryPaths() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(
      .query("Foo"),
      rawDumpingOptions: .init(useSharedCache: true)
    )
    let firstExecutor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in
        try sharedCacheInventoryData(
          cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
          imagePaths: ["/z", "/a"]
        )
      },
      runID: "run-unused-1",
      generationID: "generation-unused-1"
    )
    let reorderedExecutor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in
        try sharedCacheInventoryData(
          cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
          imagePaths: ["/a", "/z", "/a"]
        )
      },
      runID: "run-unused-2",
      generationID: "generation-unused-2"
    )
    let changedExecutor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in
        try sharedCacheInventoryData(
          cacheUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
          imagePaths: ["/a", "/z"]
        )
      },
      runID: "run-unused-3",
      generationID: "generation-unused-3"
    )
    let first = try await firstExecutor.prepare(plan)
    let reordered = try await reorderedExecutor.prepare(plan)
    let changed = try await changedExecutor.prepare(plan)
    let outputBase = fixture.outputBase.standardizedFileURL

    let firstFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
      canonicalOutputBase: outputBase,
      executionMode: .host,
      sharedCacheCohort: first.sharedCacheCohort
    )
    let reorderedFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
      canonicalOutputBase: outputBase,
      executionMode: .host,
      sharedCacheCohort: reordered.sharedCacheCohort
    )
    let changedFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
      canonicalOutputBase: outputBase,
      executionMode: .host,
      sharedCacheCohort: changed.sharedCacheCohort
    )

    #expect(firstFingerprint == reorderedFingerprint)
    #expect(firstFingerprint != changedFingerprint)
  }

  @Test func emptySharedCacheInventoryFailsDuringPreparation() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let executor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in try sharedCacheInventoryData(imagePaths: []) },
      runID: "run-unused",
      generationID: "generation-unused"
    )
    let plan = try fixture.plan(
      .query("Foo"),
      rawDumpingOptions: .init(useSharedCache: true)
    )

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await executor.prepare(plan)
    }
  }

  @Test func successfulRunPublishesImmutableGenerationAndCommitsStore() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: "first")
    let executor = fixture.executor(
      runner: runner, runID: "run-001", generationID: "generation-001")

    let result = try await executor.run(plan: try fixture.plan(.query("Foo")))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == ["framework:Foo.framework"])
    #expect(result.targetCounts.completed == 1)
    #expect(result.warnings.isEmpty)
    #expect(result.artifactDirectory == fixture.liveURL)
    #expect(try fixture.readLiveHeader() == "first")
    #expect(try fixture.readStableHeader() == "first")
    let publisher = try fixture.publisher()
    let publication = try publisher.inspect()
    #expect(publication.currentGenerationID == .init(rawValue: "generation-001"))
    let store = try GenerationStore(
      databaseURL: result.stateDatabaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(result.runID).status == .completed)
    #expect(
      try await store.targetSnapshot(targetID: "framework:Foo.framework")?.lastSuccessfulRunID
        == result.runID)
  }

  @Test func successfulTargetPublishesAndPersistsObjectiveCMetadataWarnings() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let rawResult = PrivateHeaderGeneration.RawDumping.Result(
      terminationStatus: 0,
      diagnostics: [
        .init(owner: "Objective-C protocol Z", degradation: "cycle was cut"),
        .init(owner: "Objective-C class A", degradation: "list entry was unreadable"),
        .init(owner: "Objective-C protocol Z", degradation: "cycle was cut"),
      ],
      omittedDiagnosticCount: 2
    )
    let executor = fixture.executor(
      runner: RecordingRunner(contents: "generated", result: rawResult),
      runID: "run-objc-warning",
      generationID: "generation-objc-warning"
    )

    let result = try await executor.run(plan: try fixture.plan(.query("Foo")))

    #expect(result.targetCounts.completed == 1)
    #expect(result.warnings.count == 3)
    #expect(result.warnings.allSatisfy { $0.kind == "objc-metadata-warning" })
    #expect(result.warnings.map(\.message) == result.warnings.map(\.message).sorted())
    #expect(try fixture.readLiveHeader() == "generated")
    let persisted = try DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT kind, relativePath, message FROM runLogs WHERE runID = ? ORDER BY message",
        arguments: [result.runID.rawValue]
      )
    }
    #expect(persisted.count == result.warnings.count)
    #expect(persisted.map { $0["kind"] as String } == result.warnings.map(\.kind))
    #expect(persisted.map { $0["message"] as String } == result.warnings.map(\.message))
  }

  @Test func failedTargetDoesNotPublishOrPersistObjectiveCMetadataWarnings() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let executor = fixture.executor(
      runner: RecordingRunner(
        contents: "partial",
        result: .init(
          terminationStatus: 1,
          failureSummary: "helper failed",
          diagnostics: [
            .init(owner: "Objective-C class A", degradation: "list entry was unreadable")
          ]
        )
      ),
      runID: "run-objc-failure",
      generationID: "generation-objc-failure"
    )

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await executor.run(plan: try fixture.plan(.query("Foo")))
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Foo").path))
    let persistedCount = try await DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runLogs WHERE kind = 'objc-metadata-warning'"
      ) ?? 0
    }
    #expect(persistedCount == 0)
  }

  @Test func objectiveCMetadataWarningPresentationIsBoundedAcrossTheRun() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let diagnosticCountPerTarget = 200
    let diagnostics = (0..<diagnosticCountPerTarget).map { index in
      PrivateHeaderKitRawDumpDiagnostic(
        owner: "Objective-C protocol P\(String(format: "%03d", index))",
        degradation: "cycle was cut"
      )
    }
    let runner = RecordingRunner(
      contents: "generated",
      result: .init(
        terminationStatus: 0,
        diagnostics: diagnostics,
        omittedDiagnosticCount: 3
      )
    )
    let progress = ExecutorProgressRecorder()
    let result = try await fixture.executor(
      runner: runner,
      runID: "run-objc-budget",
      generationID: "generation-objc-budget"
    ).run(
      plan: try fixture.plan(
        .identifiers(["framework:Foo.framework", "framework:Bar.framework"])
      ),
      progressReporter: { progress.record($0) }
    )

    let maximumPresented =
      PrivateHeaderGeneration.GenerationExecutor.maximumPresentedObjCMetadataWarningCount
    #expect(result.targetCounts.completed == 2)
    #expect(result.warnings.count == maximumPresented + 1)
    let aggregate = try #require(result.warnings.last)
    #expect(aggregate.relativePath == "generation.sqlite")
    #expect(
      aggregate.message.contains(
        "\(diagnosticCountPerTarget * 2 + 2 - maximumPresented) additional"
      )
    )
    let liveWarnings: [PrivateHeaderGeneration.GenerationWarning] =
      progress.events.compactMap { event in
      guard case .warning(let warning) = event else { return nil }
      return warning
    }
    #expect(liveWarnings == result.warnings)

    let persistedCount = try await DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runLogs WHERE kind = 'objc-metadata-warning'"
      ) ?? 0
    }
    #expect(persistedCount == diagnosticCountPerTarget * 2 + 2 + 1)
  }

  @Test func objectiveCWarningPersistenceFaultRollsBackTargetAndLiveReplacement() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let executor = fixture.executor(
      runner: RecordingRunner(
        contents: "generated",
        result: .init(
          terminationStatus: 0,
          diagnostics: [
            .init(owner: "Objective-C class A", degradation: "list entry was unreadable")
          ]
        )
      ),
      runID: "run-objc-warning-fault",
      generationID: "generation-objc-warning-fault",
      storeFaultInjector: { point in
        if point == .beforeRunLogWrite { throw InjectedFault.stop }
      }
    )

    await #expect(throws: InjectedFault.self) {
      _ = try await executor.run(plan: try fixture.plan(.query("Foo")))
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Foo").path))
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    let snapshot = try await store.runSnapshot(.init(rawValue: "run-objc-warning-fault"))
    #expect(snapshot.status == .running)
    #expect(snapshot.targets.first?.status == .running)
    let persistedCount = try await DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runLogs WHERE kind = 'objc-metadata-warning'"
      ) ?? 0
    }
    #expect(persistedCount == 0)
  }

  @Test func infrastructureFailureKeepsObjectiveCWarningPresentationBoundedAndAggregated()
    async throws
  {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    for framework in ["Alpha.framework", "Beta.framework", "Zeta.framework"] {
      try fixture.createFramework(framework)
    }
    let diagnosticCountPerCompletedTarget = 200
    let diagnostics = (0..<diagnosticCountPerCompletedTarget).map { index in
      PrivateHeaderKitRawDumpDiagnostic(
        owner: "Objective-C protocol P\(String(format: "%03d", index))",
        degradation: "cycle was cut"
      )
    }
    let progress = ExecutorProgressRecorder()
    let executor = fixture.executor(
      runner: RecordingRunner(
        contents: "generated",
        result: .init(terminationStatus: 0, diagnostics: diagnostics),
        hiddenPayloadFramework: "Zeta.framework"
      ),
      runID: "run-objc-budget-failure",
      generationID: "generation-objc-budget-failure"
    )

    let summary: PrivateHeaderGeneration.RunSummary
    do {
      _ = try await executor.run(
        plan: try fixture.plan(
          .identifiers([
            "framework:Alpha.framework",
            "framework:Beta.framework",
            "framework:Zeta.framework",
          ])
        ),
        progressReporter: { progress.record($0) }
      )
      Issue.record("hidden raw payload unexpectedly completed")
      return
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      summary = failure.summary
    }

    let maximumPresented =
      PrivateHeaderGeneration.GenerationExecutor.maximumPresentedObjCMetadataWarningCount
    #expect(summary.warnings.count == maximumPresented + 1)
    #expect(
      summary.warnings.last?.message.contains(
        "\(diagnosticCountPerCompletedTarget * 2 - maximumPresented) additional"
      ) == true
    )
    let liveWarnings: [PrivateHeaderGeneration.GenerationWarning] =
      progress.events.compactMap { event in
      guard case .warning(let warning) = event else { return nil }
      return warning
    }
    #expect(liveWarnings == summary.warnings)
    #expect(try fixture.readLiveHeader(framework: "Alpha") == "generated")
    #expect(try fixture.readLiveHeader(framework: "Beta") == "generated")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.liveHeaderURL(framework: "Zeta").path
      )
    )
    let persistedCount = try await DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM runLogs WHERE kind = 'objc-metadata-warning'"
      ) ?? 0
    }
    #expect(persistedCount == diagnosticCountPerCompletedTarget * 2 + 1)
  }

  @Test func completedTargetIsVisibleWhenItsFinishedEventIsReported() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let observation = LiveArtifactObservation()

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-visible",
      generationID: "generation-visible"
    ).run(
      plan: try fixture.plan(
        .identifiers(["framework:Foo.framework", "framework:Bar.framework"])
      ),
      progressReporter: { event in
        if case .targetFinished(_, _, "Foo", .completed, _) = event {
          observation.observe(fixture.liveHeaderURL(framework: "Foo"))
        }
      }
    )

    #expect(observation.contents == "generated")
    #expect(observation.errorDescription == nil)
  }

  @Test func laterInfrastructureFailureKeepsCompletedTargetVisibleAndResumeSkipsIt()
    async throws
  {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let plan = try fixture.plan(
      .identifiers(["framework:Foo.framework", "framework:Bar.framework"]),
      resumeBehavior: .resume
    )

    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(
          contents: "first-run",
          hiddenPayloadFramework: "Bar.framework"
        ),
        runID: "run-partial",
        generationID: "generation-partial"
      ).run(plan: plan)
      Issue.record("invalid second target unexpectedly completed")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.targetCounts.completed == 1)
      #expect(failure.summary.targetCounts.failed == 1)
      #expect(failure.summary.targetFailures.map(\.displayName) == ["Bar"])
    }

    #expect(try fixture.readLiveHeader(framework: "Foo") == "first-run")
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Bar").path))
    let firstStore = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    #expect(
      try await firstStore.targetSnapshot(targetID: "framework:Foo.framework")?
        .lastSuccessfulRunID == .init(rawValue: "run-partial")
    )

    let resumedRunner = RecordingRunner(contents: "resumed")
    let result = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: plan)

    #expect(await resumedRunner.invocationCount == 1)
    #expect(await resumedRunner.invocations.first?.inputPath.hasSuffix("/Bar.framework") == true)
    #expect(result.targetCounts.skipped == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "first-run")
    #expect(try fixture.readLiveHeader(framework: "Bar") == "resumed")
    #expect(try fixture.readStableHeader(framework: "Foo") == "first-run")
    #expect(try fixture.readStableHeader(framework: "Bar") == "resumed")
  }

  @Test func databaseCommitFailureRestoresPreviousTargetAndResumeReplacesItCleanly()
    async throws
  {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "uncommitted", additionalHeaderName: "Stale.h"),
        runID: "run-crashed",
        generationID: "generation-crashed",
        storeFaultInjector: { point in
          if point == .afterRunTargetWrite { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    let staleHeader = fixture.liveURL.appendingPathComponent(
      "Frameworks/Foo/Headers/Stale.h"
    )
    #expect(try fixture.readLiveHeader() == "old")
    #expect(!FileManager.default.fileExists(atPath: staleHeader.path))

    let resumedRunner = RecordingRunner(contents: "second")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-recovered",
      generationID: "generation-recovered"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await resumedRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader() == "second")
    #expect(!FileManager.default.fileExists(atPath: staleHeader.path))
  }

  @Test func recoveryDoesNotRestoreArtifactRemovedByNewerTargetPublication() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old", additionalHeaderName: "Removed.h"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    let removedHeader = fixture.liveURL.appendingPathComponent(
      "Frameworks/Foo/Headers/Removed.h"
    )
    #expect(try fixture.readLiveHeader() == "new")
    #expect(!FileManager.default.fileExists(atPath: removedHeader.path))

    let resumedRunner = RecordingRunner(contents: "unexpected")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await resumedRunner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "new")
    #expect(!FileManager.default.fileExists(atPath: removedHeader.path))
  }

  @Test func recoveryPreservesCaseOnlyNewerTargetPublication() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    let volumeValues = try fixture.liveURL.resourceValues(
      forKeys: [.volumeSupportsCaseSensitiveNamesKey]
    )
    guard volumeValues.volumeSupportsCaseSensitiveNames == false else { return }

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new", primaryHeaderName: "generated.h"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    let lowercasedLiveHeader = fixture.liveURL.appendingPathComponent(
      "Frameworks/Foo/Headers/generated.h"
    )
    #expect(try String(contentsOf: lowercasedLiveHeader, encoding: .utf8) == "new")

    let resumedRunner = RecordingRunner(contents: "unexpected")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    let lowercasedStableHeader = fixture.stableURL.appendingPathComponent(
      "Frameworks/Foo/Headers/generated.h"
    )
    #expect(await resumedRunner.invocationCount == 0)
    #expect(try String(contentsOf: lowercasedLiveHeader, encoding: .utf8) == "new")
    #expect(try String(contentsOf: lowercasedStableHeader, encoding: .utf8) == "new")
    #expect(
      try fixture.publisher().inspect().currentMarker?
        .artifactsByTarget["framework:Foo.framework"]?.map(\.rawValue)
        == ["Frameworks/Foo/Headers/generated.h"]
    )
  }

  @Test func recoveryRerunsNewerTargetInsteadOfHydratingOlderBytes() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    try FileManager.default.removeItem(at: fixture.liveHeaderURL())

    let resumedRunner = RecordingRunner(contents: "recovered")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await resumedRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader() == "recovered")
  }

  @Test func recoveryRerunsNewerTargetWhoseLiveContentsChanged() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    try Data("tampered".utf8).write(to: fixture.liveHeaderURL())

    let resumedRunner = RecordingRunner(contents: "recovered")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await resumedRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader() == "recovered")
    #expect(try fixture.readStableHeader() == "recovered")
  }

  @Test func snapshotRebuildDropsPublishedTargetThatIsMissingFromLiveOutput() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old", additionalHeaderName: "Removed.h"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new", additionalHeaderName: "Still.h"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    try FileManager.default.removeItem(at: fixture.liveHeaderURL(framework: "Foo"))

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "bar"),
      runID: "run-bar",
      generationID: "generation-bar"
    ).run(plan: try fixture.plan(.query("Bar"), resumeBehavior: .fresh))

    let marker = try #require(fixture.publisher().inspect().currentMarker)
    #expect(marker.artifactsByTarget.keys.sorted() == ["framework:Bar.framework"])
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL.appendingPathComponent(
        "Frameworks/Foo/Headers/Still.h"
      ).path
    ))
    try FileManager.default.createDirectory(
      at: fixture.liveHeaderURL(framework: "Foo").deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "untrusted".write(
      to: fixture.liveHeaderURL(framework: "Foo"),
      atomically: true,
      encoding: .utf8
    )
    let recoveredRunner = RecordingRunner(contents: "recovered")
    _ = try await fixture.executor(
      runner: recoveredRunner,
      runID: "run-recovered",
      generationID: "generation-recovered"
    ).run(
      plan: try fixture.plan(
        .identifiers(["framework:Foo.framework", "framework:Bar.framework"]),
        resumeBehavior: .resume
      )
    )
    #expect(await recoveredRunner.invocationCount == 1)
    #expect(
      await recoveredRunner.invocations.first?.inputPath.hasSuffix("/Foo.framework") == true
    )
    #expect(try fixture.readLiveHeader(framework: "Foo") == "recovered")
    #expect(try fixture.readStableHeader(framework: "Foo") == "recovered")
    #expect(try fixture.readStableHeader(framework: "Bar") == "bar")
  }

  @Test func compatibleResumeSkipsCurrentCompletedTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: plan)
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(plan: plan)

    #expect(await secondRunner.invocationCount == 0)
    #expect(result.generatedTargets.isEmpty)
    #expect(result.targetCounts.skipped == 1)
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func compatibleResumeRestoresModifiedCurrentArtifactBeforeSkipping() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: plan)
    try "tampered".write(
      to: fixture.liveHeaderURL(),
      atomically: true,
      encoding: .utf8
    )
    let runner = RecordingRunner(contents: "unexpected")

    let result = try await fixture.executor(
      runner: runner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: plan)

    #expect(await runner.invocationCount == 0)
    #expect(result.targetCounts.skipped == 1)
    #expect(try fixture.readLiveHeader() == "first")
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func nextSnapshotUsesCanonicalBytesForCoveredTargetAfterLiveMutation() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: try fixture.plan(.query("Foo")))
    let mutation = FileMutationRecorder()
    let fooLiveHeader = fixture.liveHeaderURL(framework: "Foo")
    let barRunner = RecordingRunner(contents: "bar") {
      mutation.run {
        try "tampered".write(to: fooLiveHeader, atomically: true, encoding: .utf8)
      }
    }

    _ = try await fixture.executor(
      runner: barRunner,
      runID: "run-bar",
      generationID: "generation-bar"
    ).run(plan: try fixture.plan(.query("Bar"), resumeBehavior: .fresh))

    #expect(mutation.message == nil)
    #expect(await barRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "first")
    #expect(try fixture.readStableHeader(framework: "Foo") == "first")
    #expect(try fixture.readLiveHeader(framework: "Bar") == "bar")
    #expect(try fixture.readStableHeader(framework: "Bar") == "bar")
  }

  @Test func finalSnapshotRejectsGeneratedStagingChangedAfterLivePublication() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let mutation = FileMutationRecorder()
    let fooStagedHeader = fixture.stagedHeaderURL(runID: "run-generated", framework: "Foo")
    let barStagedHeader = fixture.stagedHeaderURL(runID: "run-generated", framework: "Bar")
    let runner = RecordingRunner(contents: "generated") {
      guard FileManager.default.fileExists(atPath: barStagedHeader.path) else { return }
      mutation.run {
        try "tampered".write(to: fooStagedHeader, atomically: true, encoding: .utf8)
      }
    }

    do {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-generated",
        generationID: "generation-generated"
      ).run(plan: try fixture.plan(.query("Foo,Bar"), resumeBehavior: .fresh))
      Issue.record("changed generated staging unexpectedly became an immutable generation")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.targetCounts.completed == 2)
      #expect(failure.message.contains("artifact contents do not match published target"))
    }

    #expect(mutation.message == nil)
    #expect(await runner.invocationCount == 2)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "generated")
    #expect(try fixture.readLiveHeader(framework: "Bar") == "generated")
    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
  }

  @Test func finalSnapshotFailsBeforeRetiringNewerLiveOutputChangedDuringRun() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-new",
        generationID: "generation-new",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    let previousGenerationID = try #require(fixture.publisher().inspect().currentGenerationID)
    let mutation = FileMutationRecorder()
    let runner = RecordingRunner(contents: "bar") {
      mutation.run {
        try "tampered".write(
          to: fixture.liveHeaderURL(framework: "Foo"),
          atomically: true,
          encoding: .utf8
        )
      }
    }

    do {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-resumed",
        generationID: "generation-resumed"
      ).run(plan: try fixture.plan(.query("Foo,Bar"), resumeBehavior: .resume))
      Issue.record("changed newer live output unexpectedly became an immutable generation")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.targetCounts.completed == 1)
      #expect(failure.summary.targetCounts.skipped == 1)
      #expect(failure.message.contains("published target contents changed during generation"))
    }

    #expect(mutation.message == nil)
    #expect(await runner.invocationCount == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "tampered")
    #expect(try fixture.readLiveHeader(framework: "Bar") == "bar")
    #expect(try fixture.readStableHeader(framework: "Foo") == "old")
    #expect(try fixture.publisher().inspect().currentGenerationID == previousGenerationID)
  }

  @Test func failedAndPartialAttemptsPreserveLastSuccessfulGeneration() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: try fixture.plan(.query("Foo")))
    let oldCurrent = try fixture.publisher().inspect().currentGenerationID
    let partialPlan = try fixture.plan(.query("Foo"), resumeBehavior: .fresh)
    let partialRunner = RecordingRunner(
      contents: "uncommitted",
      result: .init(terminationStatus: 7, failureSummary: "raw dump failed")
    )

    do {
      _ = try await fixture.executor(
        runner: partialRunner,
        runID: "run-002",
        generationID: "generation-002"
      ).run(plan: partialPlan)
      Issue.record("partial run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
      #expect(failure.summary.runID == .init(rawValue: "run-002"))
      #expect(failure.summary.status == .partial)
      #expect(failure.summary.targetCounts.partial == 1)
      #expect(failure.summary.artifactDirectory == fixture.liveURL)
      #expect(failure.summary.stateDatabaseURL == fixture.databaseURL)
      #expect(failure.failedTargetIDs == ["framework:Foo.framework"])
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == oldCurrent)
    #expect(try fixture.readLiveHeader() == "old")
    #expect(try fixture.readStableHeader() == "old")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(.init(rawValue: "run-002")).status == .partial)
    #expect(
      try await store.targetSnapshot(targetID: "framework:Foo.framework")?.lastSuccessfulRunID
        == .init(rawValue: "run-001"))
  }

  @Test func zeroSuccessfulTargetsNeverCreateOrSwitchPointer() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: nil, thrownError: InjectedFault.rawFailure)

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-failed",
        generationID: "generation-unused"
      ).run(plan: try fixture.plan(.query("Foo")))
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.stableURL.path))
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(.init(rawValue: "run-failed")).status == .failed)
  }

  @Test func cancellationAfterOneCompletionPublishesOnlyCompletedTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let runner = RecordingRunner(contents: "generated", cancelsForFramework: "Bar.framework")
    let progress = ExecutorProgressRecorder()
    let plan = try fixture.plan(
      .identifiers([
        "framework:Foo.framework",
        "framework:Bar.framework",
      ]))

    do {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-cancelled",
        generationID: "generation-partial"
      ).run(
        plan: plan,
        progressReporter: { event in
          progress.record(event)
        })
      Issue.record("interrupted run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runInterrupted(interruption) {
      #expect(interruption.summary.status == .interrupted)
      #expect(interruption.summary.targetCounts.completed == 1)
      #expect(interruption.summary.targetCounts.interrupted == 1)
    }

    #expect(await runner.invocationCount == 2)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "generated")
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Bar").path))
    #expect(try fixture.readStableHeader(framework: "Foo") == "generated")
    #expect(!FileManager.default.fileExists(atPath: fixture.stableHeaderURL(framework: "Bar").path))
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    let run = try await store.runSnapshot(.init(rawValue: "run-cancelled"))
    #expect(run.status == .interrupted)
    let statuses = Dictionary(uniqueKeysWithValues: run.targets.map { ($0.targetID, $0.status) })
    #expect(statuses["framework:Foo.framework"] == .completed)
    #expect(statuses["framework:Bar.framework"] == .interrupted)
    let summaries: [PrivateHeaderGeneration.RunSummary] = progress.events.compactMap { event in
      guard case .runFinished(let summary) = event else { return nil }
      return summary
    }
    let summary = try #require(summaries.last)
    #expect(summary.status == .interrupted)
    #expect(summary.targetCounts.completed == 1)
    #expect(summary.targetCounts.interrupted == 1)
    #expect(summary.artifactDirectory == fixture.liveURL)
    #expect(summary.stateDatabaseURL == fixture.databaseURL)
  }

  @Test(arguments: [
    PrivateHeaderGeneration.PublicationFaultPoint.afterPrepared,
    .afterGenerationMove,
    .afterCurrentPointerSwitch,
    .afterStablePointerSwitch,
    .beforeCommitted,
  ])
  func cancellationAtEveryPublicationBoundaryCommitsInterruptedSummary(
    _ cancellationPoint: PrivateHeaderGeneration.PublicationFaultPoint
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: "generated")
    let plan = try fixture.plan(.query("Foo"))

    let capturedInterruption = await captureInterruption {
      try await fixture.executor(
        runner: runner,
        runID: "run-interrupted",
        generationID: "generation-interrupted",
        publicationFaultInjector: { point in
          if point == cancellationPoint {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      ).run(plan: plan)
    }
    let interruption = try #require(capturedInterruption)
    #expect(interruption.summary.status == .interrupted)
    #expect(interruption.summary.targetCounts.completed == 1)
    #expect(interruption.summary.artifactDirectory == fixture.liveURL)

    #expect(await runner.invocationCount == 1)
    #expect(try fixture.readStableHeader() == "generated")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(.init(rawValue: "run-interrupted")).status == .interrupted)
    #expect(
      try await store.publicationIntent(generationID: .init(rawValue: "generation-interrupted"))?
        .state == .committed)
  }

  @Test func cancellationLatchedImmediatelyAfterRawResultDoesNotPublishTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(
      contents: "unpublished",
      afterRun: { withUnsafeCurrentTask { $0?.cancel() } }
    )
    let plan = try fixture.plan(.query("Foo"))

    let capturedInterruption = await captureInterruption {
      try await fixture.executor(
        runner: runner,
        runID: "run-after-raw-cancel",
        generationID: "generation-unused"
      ).run(plan: plan)
    }
    #expect(try #require(capturedInterruption).summary.targetCounts.interrupted == 1)
    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
  }

  @Test func cancellationDuringPublicationFinalizeCommitsInterruptedStatus() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))

    let capturedInterruption = await captureInterruption {
      try await fixture.executor(
        runner: RecordingRunner(contents: "generated"),
        runID: "run-finalize-cancel",
        generationID: "generation-finalize-cancel",
        storeFaultInjector: { point in
          if point == .afterSemanticFinalize {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      ).run(plan: plan)
    }
    let interruption = try #require(capturedInterruption)
    #expect(interruption.summary.status == .interrupted)
    #expect(interruption.summary.targetCounts.completed == 1)
    #expect(try fixture.readStableHeader() == "generated")
  }

  @Test func cancellationDuringZeroSuccessFinalizeWinsOverFailure() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))

    let capturedInterruption = await captureInterruption {
      try await fixture.executor(
        runner: RecordingRunner(contents: nil, thrownError: InjectedFault.rawFailure),
        runID: "run-zero-finalize-cancel",
        generationID: "generation-unused",
        storeFaultInjector: { point in
          if point == .beforeTerminalRunCommit {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      ).run(plan: plan)
    }
    let interruption = try #require(capturedInterruption)
    #expect(interruption.summary.status == .interrupted)
    #expect(interruption.summary.targetCounts.failed == 1)
    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
  }

  @Test func cancellationDuringNoOpResumeFinalizeReturnsTypedInterruption() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: plan)
    let capturedInterruption = await captureInterruption {
      try await fixture.executor(
        runner: RecordingRunner(contents: "unused"),
        runID: "run-noop-cancel",
        generationID: "generation-unused",
        storeFaultInjector: { point in
          if point == .beforeTerminalRunCommit {
            withUnsafeCurrentTask { $0?.cancel() }
          }
        }
      ).run(plan: plan)
    }
    let interruption = try #require(capturedInterruption)
    #expect(interruption.summary.status == .interrupted)
    #expect(interruption.summary.targetCounts.skipped == 1)
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func crashAfterCurrentSwitchRollsForwardBeforeResume() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))
    let firstRunner = RecordingRunner(contents: "recoverable")
    let first = fixture.executor(
      runner: firstRunner,
      runID: "run-001",
      generationID: "generation-001",
      publicationFaultInjector: { point in
        if point == .afterCurrentPointerSwitch { throw InjectedFault.stop }
      }
    )
    await #expect(throws: InjectedFault.self) {
      _ = try await first.run(plan: plan)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.stableURL.path))
    let secondRunner = RecordingRunner(contents: "should-not-run")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(plan: plan)

    #expect(await secondRunner.invocationCount == 0)
    #expect(try fixture.readStableHeader() == "recoverable")
    let store = try GenerationStore(
      databaseURL: result.stateDatabaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(.init(rawValue: "run-001")).status == .completed)
    #expect(
      try await store.publicationIntent(generationID: .init(rawValue: "generation-001"))?.state
        == .committed)
  }

  @Test(arguments: [
    PrivateHeaderGeneration.PublicationFaultPoint.afterPrepared,
    .afterGenerationMove,
    .afterCurrentPointerSwitch,
    .afterStablePointerSwitch,
    .beforeCommitted,
  ])
  func publicationFaultMatrixRecoversToOneCoherentTerminalState(
    _ faultPoint: PrivateHeaderGeneration.PublicationFaultPoint
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"), resumeBehavior: .resume)
    let firstRunner = RecordingRunner(contents: "first-attempt")
    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: firstRunner,
        runID: "run-001",
        generationID: "generation-001",
        publicationFaultInjector: { point in
          if point == faultPoint { throw InjectedFault.stop }
        }
      ).run(plan: plan)
    }
    let secondRunner = RecordingRunner(contents: "second-attempt")

    _ = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(plan: plan)

    let firstSnapshotWasAborted =
      faultPoint == .afterPrepared || faultPoint == .afterGenerationMove
    #expect(await secondRunner.invocationCount == 0)
    let expectedGeneration = PrivateHeaderGeneration.GenerationID(
      rawValue: firstSnapshotWasAborted ? "generation-002" : "generation-001"
    )
    let publication = try fixture.publisher().inspect()
    #expect(publication.currentGenerationID == expectedGeneration)
    #expect(try fixture.readLiveHeader() == "first-attempt")
    #expect(try fixture.readStableHeader() == "first-attempt")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    let firstIntent = try #require(
      try await store.publicationIntent(generationID: .init(rawValue: "generation-001"))
    )
    #expect(firstIntent.state == (firstSnapshotWasAborted ? .aborted : .committed))
    #expect(
      try await store.runSnapshot(.init(rawValue: "run-001")).status
        == (firstSnapshotWasAborted ? .interrupted : .completed))
    if firstSnapshotWasAborted {
      #expect(!publication.validGenerationIDs.contains(.init(rawValue: "generation-001")))
      #expect(
        try await store.publicationIntent(generationID: .init(rawValue: "generation-002"))?.state
          == .committed)
    }
  }

  @Test(arguments: [
    PrivateHeaderGeneration.PublicationFaultPoint.afterPrepared,
    .afterGenerationMove,
  ])
  func abortedFinalSnapshotKeepsPublishedTargetAndResumeDoesNotRerun(
    _ faultPoint: PrivateHeaderGeneration.PublicationFaultPoint
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old-content"),
      runID: "run-old",
      generationID: "generation-old"
    ).run(plan: try fixture.plan(.query("Foo")))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "unpublished-content"),
        runID: "run-unpublished",
        generationID: "generation-unpublished",
        publicationFaultInjector: { point in
          if point == faultPoint { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    let resumedRunner = RecordingRunner(contents: "resumed-content")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await resumedRunner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "unpublished-content")
    #expect(try fixture.readStableHeader() == "unpublished-content")
    #expect(
      try fixture.publisher().inspect().currentGenerationID
        == .init(rawValue: "generation-resumed")
    )
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    #expect(
      try await store.targetSnapshot(targetID: "framework:Foo.framework")?.lastSuccessfulRunID
        == .init(rawValue: "run-unpublished")
    )
  }

  @Test func resumeDropsOpaqueOwnershipAlreadyClaimedByAPublishedTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    try fixture.createFramework("Baz.framework")
    let legacyFooHeader = fixture.stableHeaderURL(framework: "Foo")
    try FileManager.default.createDirectory(
      at: legacyFooHeader.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "legacy".write(to: legacyFooHeader, atomically: true, encoding: .utf8)

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "bar"),
      runID: "run-seed",
      generationID: "generation-seed"
    ).run(plan: try fixture.plan(.query("Bar"), resumeBehavior: .fresh))

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "foo"),
        runID: "run-claim",
        generationID: "generation-claim",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    try FileManager.default.removeItem(at: fixture.liveHeaderURL(framework: "Foo"))

    let resumedRunner = RecordingRunner(contents: "baz")
    _ = try await fixture.executor(
      runner: resumedRunner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Baz"), resumeBehavior: .fresh))

    #expect(await resumedRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader(framework: "Baz") == "baz")
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Foo").path))
    #expect(
      try fixture.publisher().inspect().currentMarker?.opaquePaths.contains(
        PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Headers/Generated.h")
      ) == false
    )

    let fooRunner = RecordingRunner(contents: "regenerated-foo")
    _ = try await fixture.executor(
      runner: fooRunner,
      runID: "run-foo",
      generationID: "generation-foo"
    ).run(plan: try fixture.plan(.query("Foo,Baz"), resumeBehavior: .resume))

    #expect(await fooRunner.invocationCount == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "regenerated-foo")
  }

  @Test func generationMoveFailureAbortsAsFailedAndPreservesPreviousCurrent() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: try fixture.plan(.query("Foo")))
    let previousGenerationID = try #require(fixture.publisher().inspect().currentGenerationID)
    let mutation = FileMutationRecorder()
    let draftURL = fixture.outputBase
      .appendingPathComponent(".privateheaderkit/\(fixture.sourceLabel)/staging", isDirectory: true)
      .appendingPathComponent("generation-002.draft", isDirectory: true)

    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-002",
        generationID: "generation-002",
        publicationFaultInjector: { point in
          guard point == .afterPrepared else { return }
          mutation.run {
            try FileManager.default.removeItem(at: draftURL)
          }
        }
      ).run(
        plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh)
      )
      Issue.record("missing prepared generation unexpectedly moved and committed")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.status == .failed)
      #expect(failure.summary.targetCounts.completed == 1)
      #expect(failure.summary.targetCounts.failed == 0)
      #expect(failure.message.contains("missing marker"))
    }

    #expect(mutation.message == nil)
    #expect(try fixture.publisher().inspect().currentGenerationID == previousGenerationID)
    #expect(try fixture.readLiveHeader() == "new")
    #expect(try fixture.readStableHeader() == "old")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    let run = try await store.runSnapshot(.init(rawValue: "run-002"))
    #expect(run.status == .failed)
    #expect(run.targets.first?.status == .completed)
    #expect(
      try await store.publicationIntent(generationID: .init(rawValue: "generation-002"))?.state
      == .aborted)
  }

  @Test func changedPreparedGenerationNeverReachesLiveOrManagedOutput() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: try fixture.plan(.query("Foo")))
    let previousGenerationID = try #require(fixture.publisher().inspect().currentGenerationID)
    let mutation = FileMutationRecorder()
    let draftHeader = fixture.outputBase
      .appendingPathComponent(".privateheaderkit/\(fixture.sourceLabel)/staging", isDirectory: true)
      .appendingPathComponent("generation-002.draft", isDirectory: true)
      .appendingPathComponent("Frameworks/Foo/Headers/Generated.h")

    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "new"),
        runID: "run-002",
        generationID: "generation-002",
        publicationFaultInjector: { point in
          guard point == .afterPrepared else { return }
          mutation.run {
            try "tampered".write(to: draftHeader, atomically: true, encoding: .utf8)
          }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
      Issue.record("changed prepared generation unexpectedly committed")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.status == .failed)
      #expect(failure.summary.targetCounts.completed == 1)
      #expect(failure.message.contains("artifact content digest does not match marker"))
    }

    #expect(mutation.message == nil)
    let failedPublication = try fixture.publisher().inspect()
    #expect(failedPublication.currentGenerationID == previousGenerationID)
    #expect(!failedPublication.validGenerationIDs.contains(.init(rawValue: "generation-002")))
    #expect(try fixture.readLiveHeader() == "new")
    #expect(try fixture.readStableHeader() == "old")

    let retryRunner = RecordingRunner(contents: "should-not-run")
    _ = try await fixture.executor(
      runner: retryRunner,
      runID: "run-003",
      generationID: "generation-003"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await retryRunner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "new")
    #expect(try fixture.readStableHeader() == "new")
  }

  @Test func staleAttemptCleanupPreservesArtifactsOwnedByAnotherTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let legacyOpaqueArtifact = fixture.stableURL.appendingPathComponent("User/keep.txt")
    try FileManager.default.createDirectory(
      at: legacyOpaqueArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "opaque".write(to: legacyOpaqueArtifact, atomically: true, encoding: .utf8)
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "bar"),
      runID: "run-bar",
      generationID: "generation-bar"
    ).run(plan: try fixture.plan(.query("Bar"), resumeBehavior: .fresh))

    let store = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    let staleRunID = PrivateHeaderGeneration.RunID(rawValue: "run-stale-foo")
    let staleDate = Date(timeIntervalSinceReferenceDate: 90)
    _ = try await store.beginRun(
      id: staleRunID,
      plan: .init(
        sourceIdentity: fixture.source.storageIdentifier,
        fingerprint: "stale-attempt",
        targetIDs: ["framework:Foo.framework"],
        toolCompatibilityIdentity: "test"
      ),
      at: staleDate
    )
    try await store.beginTargetAttempt(
      targetID: "framework:Foo.framework",
      displayName: "Foo.framework",
      kind: "framework",
      in: staleRunID,
      at: staleDate
    )
    try await store.recordTargetAttempt(
      .init(
        targetID: "framework:Foo.framework",
        displayName: "Foo.framework",
        kind: "framework",
        status: .partial,
        artifacts: [
          .init(rawValue: "Frameworks/Bar/Headers/Generated.h"),
          .init(rawValue: "User/keep.txt"),
        ],
        failureSummary: "stale partial output",
        completedAt: staleDate
      ),
      in: staleRunID
    )
    _ = try await store.finishRunWithoutPublication(staleRunID, at: staleDate)

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "foo"),
        runID: "run-foo",
        generationID: "generation-foo",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    #expect(try fixture.readLiveHeader(framework: "Bar") == "bar")
    #expect(try fixture.readStableHeader(framework: "Bar") == "bar")
    #expect(try fixture.readLiveHeader(framework: "Foo") == "foo")
    #expect(
      try String(
        contentsOf: fixture.liveURL.appendingPathComponent("User/keep.txt"),
        encoding: .utf8
      ) == "opaque"
    )
    #expect(
      try String(
        contentsOf: fixture.stableURL.appendingPathComponent("User/keep.txt"),
        encoding: .utf8
      ) == "opaque"
    )
  }

  @Test func freshRunRebuildsStateWhenManagedGenerationOutlivesDatabase() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first", additionalHeaderName: "Removed.h"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: try fixture.plan(.query("Foo")))
    try fixture.removeDatabaseFiles()
    let runner = RecordingRunner(contents: "regenerated")
    let executor = fixture.executor(
      runner: runner,
      runID: "run-regenerated",
      generationID: "generation-regenerated"
    )
    let preparedPlan = try await executor.prepare(
      fixture.plan(.query("Foo"), resumeBehavior: .fresh)
    )

    #expect(try await executor.availableResumeSummary(for: preparedPlan) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    let result = try await executor.run(preparedPlan)

    #expect(await runner.invocationCount == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "regenerated")
    #expect(try fixture.readStableHeader() == "regenerated")
    #expect(!FileManager.default.fileExists(
      atPath: fixture.liveURL.appendingPathComponent(
        "Frameworks/Foo/Headers/Removed.h"
      ).path
    ))
  }

  @Test func resumeSummaryRebuildsStateWhenManagedGenerationOutlivesDatabase() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.query("Foo"))
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: plan)
    try fixture.removeDatabaseFiles()
    let runner = RecordingRunner(contents: "unexpected")
    let executor = fixture.executor(
      runner: runner,
      runID: "run-summary",
      generationID: "generation-summary"
    )
    let preparedPlan = try await executor.prepare(plan)

    #expect(try await executor.availableResumeSummary(for: preparedPlan) == nil)
    #expect(await runner.invocationCount == 0)
    #expect(FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    #expect(try fixture.readLiveHeader() == "first")
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func resumeRunRebuildsStateWhenManagedGenerationOutlivesDatabase() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: try fixture.plan(.query("Foo")))
    try fixture.removeDatabaseFiles()
    let runner = RecordingRunner(contents: "unexpected")

    let result = try await fixture.executor(
      runner: runner,
      runID: "run-resumed",
      generationID: "generation-resumed"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .resume))

    #expect(await runner.invocationCount == 0)
    #expect(result.targetCounts.skipped == 1)
    #expect(try fixture.readLiveHeader() == "first")
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func freshDatabaseBootstrapSurvivesFailedPublicationAndRetries() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-first",
      generationID: "generation-first"
    ).run(plan: try fixture.plan(.query("Foo")))
    try fixture.removeDatabaseFiles()

    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "unpublished"),
        runID: "run-faulted",
        generationID: "generation-faulted",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    let runner = RecordingRunner(contents: "recovered")
    let result = try await fixture.executor(
      runner: runner,
      runID: "run-recovered",
      generationID: "generation-recovered"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    #expect(await runner.invocationCount == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "recovered")
    #expect(try fixture.readStableHeader() == "recovered")
  }

  @Test func freshDatabaseBootstrapCompletesMissingStablePointer() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "first"),
        runID: "run-first",
        generationID: "generation-first",
        publicationFaultInjector: { point in
          if point == .afterCurrentPointerSwitch { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    #expect(try fixture.publisher().inspect().stablePathState == .absent)
    try fixture.removeDatabaseFiles()

    let runner = RecordingRunner(contents: "regenerated")
    _ = try await fixture.executor(
      runner: runner,
      runID: "run-regenerated",
      generationID: "generation-regenerated"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    #expect(await runner.invocationCount == 1)
    #expect(try fixture.publisher().inspect().stablePathState == .managed)
    #expect(try fixture.readLiveHeader() == "regenerated")
    #expect(try fixture.readStableHeader() == "regenerated")
  }

  @Test func freshDatabaseBootstrapKeepsReplacementPublishedByCurrentGeneration() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "new"),
      runID: "run-new",
      generationID: "generation-new"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    try "old".write(
      to: fixture.liveHeaderURL(framework: "Foo"),
      atomically: true,
      encoding: .utf8
    )
    let artifact = try PrivateHeaderGeneration.ArtifactPath(
      "Frameworks/Foo/Headers/Generated.h"
    )
    let replacementInput = fixture.stateDirectory.appendingPathComponent(
      "replacement-input",
      isDirectory: true
    )
    let stagedSource = replacementInput.appendingPathComponent("output", isDirectory: true)
    let stagedHeader = stagedSource.appendingPathComponent("Headers/Generated.h")
    try FileManager.default.createDirectory(
      at: stagedHeader.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "new".write(to: stagedHeader, atomically: true, encoding: .utf8)
    let replacementStore = PrivateHeaderGeneration.ArtifactStore(
      artifactRoot: fixture.liveURL
    )
    let replacementDirectory = fixture.stateDirectory
      .appendingPathComponent("replacements/run-new", isDirectory: true)
      .appendingPathComponent("framework%3AFoo.framework", isDirectory: true)
    let replacement = try replacementStore.prepareReplacement(
      stagingDirectory: replacementInput,
      stagedSourceDirectory: stagedSource,
      artifactRoot: try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo"),
      artifacts: [artifact],
      removing: [artifact],
      runID: .init(rawValue: "run-new"),
      targetID: "framework:Foo.framework",
      at: replacementDirectory
    )
    try replacementStore.applyReplacement(replacement)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "new")
    try fixture.removeDatabaseFiles()

    let runner = RecordingRunner(contents: "bar")
    _ = try await fixture.executor(
      runner: runner,
      runID: "run-bar",
      generationID: "generation-bar"
    ).run(plan: try fixture.plan(.query("Bar"), resumeBehavior: .fresh))

    #expect(await runner.invocationCount == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "new")
    #expect(try fixture.readStableHeader(framework: "Foo") == "new")
    #expect(try fixture.readStableHeader(framework: "Bar") == "bar")
    #expect(!FileManager.default.fileExists(atPath: replacementDirectory.path))
  }

  @Test func freshDatabaseBootstrapRejectsUnauthenticatedSamePathLiveBytes() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "stable"),
      runID: "run-stable",
      generationID: "generation-stable"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "incremental"),
        runID: "run-incremental",
        generationID: "generation-incremental",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    try fixture.removeDatabaseFiles()
    let runner = RecordingRunner(contents: "must-not-run")

    await #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-retry",
        generationID: "generation-retry"
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    #expect(await runner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "incremental")
    #expect(try fixture.readStableHeader() == "stable")

    let summaryRunner = RecordingRunner(contents: "must-not-run")
    let summaryExecutor = fixture.executor(
      runner: summaryRunner,
      runID: "run-summary",
      generationID: "generation-summary"
    )
    let summaryPlan = try await summaryExecutor.prepare(
      fixture.plan(.query("Foo"), resumeBehavior: .resume)
    )
    await #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try await summaryExecutor.availableResumeSummary(for: summaryPlan)
    }
    #expect(await summaryRunner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "incremental")

    let secondRetryRunner = RecordingRunner(contents: "must-not-run")
    await #expect(throws: PrivateHeaderGeneration.ArtifactStoreError.self) {
      _ = try await fixture.executor(
        runner: secondRetryRunner,
        runID: "run-second-retry",
        generationID: "generation-second-retry"
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    #expect(await secondRetryRunner.invocationCount == 0)
    #expect(try fixture.readLiveHeader() == "incremental")
  }

  @Test func freshDatabaseBootstrapPreservesUnauthenticatedAdditionalLiveFile() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "stable"),
      runID: "run-stable",
      generationID: "generation-stable"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    await #expect(throws: InjectedFault.self) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "stable", additionalHeaderName: "Additional.h"),
        runID: "run-incremental",
        generationID: "generation-incremental",
        publicationFaultInjector: { point in
          if point == .afterPrepared { throw InjectedFault.stop }
        }
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }
    try fixture.removeDatabaseFiles()
    let additionalHeader = fixture.liveURL.appendingPathComponent(
      "Frameworks/Foo/Headers/Additional.h"
    )
    let runner = RecordingRunner(contents: "must-not-run")

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-retry",
        generationID: "generation-retry"
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    #expect(await runner.invocationCount == 0)
    #expect(FileManager.default.fileExists(atPath: additionalHeader.path))
    #expect(try String(contentsOf: additionalHeader, encoding: .utf8) == "stable")
  }

  @Test func legacyJSONGateRunsBeforeDatabaseCreationOnEveryRetry() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try FileManager.default.createDirectory(
      at: fixture.stateDirectory, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: fixture.stateDirectory.appendingPathComponent("manifest.json"))
    let plan = try fixture.plan(.query("Foo"))

    for suffix in ["one", "two"] {
      await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
        _ = try await fixture.executor(
          runner: RecordingRunner(contents: "unused"),
          runID: "run-\(suffix)",
          generationID: "generation-\(suffix)"
        ).run(plan: plan)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }
  }

  @Test func combinedLegacyStateAndArtifactsAreReportedBeforeDatabaseCreation() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try FileManager.default.createDirectory(
      at: fixture.stateDirectory,
      withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(
      to: fixture.stateDirectory.appendingPathComponent("manifest.json")
    )
    try FileManager.default.createDirectory(
      at: fixture.stableURL,
      withIntermediateDirectories: true
    )
    try Data("legacy".utf8).write(
      to: fixture.stableURL.appendingPathComponent("Unknown.txt")
    )
    let executor = fixture.executor(
      runner: RecordingRunner(contents: "unused"),
      runID: "run-unused",
      generationID: "generation-unused"
    )
    let preparedPlan = try await executor.prepare(try fixture.plan(.query("Foo")))

    do {
      _ = try await executor.availableResumeSummary(for: preparedPlan)
      Issue.record("combined legacy migration unexpectedly returned a resume summary")
    } catch let PrivateHeaderGeneration.GenerationError.legacyMigrationRequiresFresh(
      requirement
    ) {
      guard case .stateAndArtifacts(let statePath, let artifactsPath) = requirement else {
        Issue.record("unexpected legacy migration requirement: \(requirement)")
        return
      }
      #expect(statePath == fixture.stateDirectory.path)
      #expect(artifactsPath == fixture.stableURL.path)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.liveURL.path))
  }

  @Test func freshLegacyMigrationPublishesOpaqueArtifactInLiveOutput() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let legacyArtifact = fixture.stableURL.appendingPathComponent("Notes/custom.txt")
    try FileManager.default.createDirectory(
      at: legacyArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "opaque".write(to: legacyArtifact, atomically: true, encoding: .utf8)

    let result = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-legacy",
      generationID: "generation-legacy"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    let liveArtifact = fixture.liveURL.appendingPathComponent("Notes/custom.txt")
    #expect(result.artifactDirectory == fixture.liveURL)
    #expect(try String(contentsOf: liveArtifact, encoding: .utf8) == "opaque")
    #expect(try String(contentsOf: fixture.stableURL.appendingPathComponent("Notes/custom.txt"), encoding: .utf8) == "opaque")
    let publisher = try ArtifactPublisher(
      artifactBaseDirectory: fixture.outputBase,
      sourceLabel: fixture.sourceLabel
    )
    #expect(
      try publisher.inspect().currentMarker?.opaquePaths
        == [PrivateHeaderGeneration.ArtifactPath(rawValue: "Notes/custom.txt")]
    )
  }

  @Test func freshLegacyMigrationKeepsGeneratedClaimOverOpaquePath() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let claimedArtifact = fixture.stableURL.appendingPathComponent(
      "Frameworks/Foo/Headers/Generated.h"
    )
    try FileManager.default.createDirectory(
      at: claimedArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "legacy".write(to: claimedArtifact, atomically: true, encoding: .utf8)

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-claim",
      generationID: "generation-claim"
    ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))

    #expect(try fixture.readLiveHeader() == "generated")
    let publisher = try ArtifactPublisher(
      artifactBaseDirectory: fixture.outputBase,
      sourceLabel: fixture.sourceLabel
    )
    let marker = try #require(publisher.inspect().currentMarker)
    #expect(marker.opaquePaths.isEmpty)
    #expect(
      marker.artifactsByTarget["framework:Foo.framework"]
        == [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Headers/Generated.h")]
    )
  }

  @Test(arguments: [
    "Frameworks/Foo/headers/Generated.h",
    "Frameworks/Foo/Headers",
  ])
  func freshLegacyCollisionFailsBeforePublishingTargetOwnership(
    _ legacyPath: String
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let legacyArtifact = fixture.stableURL.appendingPathComponent(legacyPath)
    try FileManager.default.createDirectory(
      at: legacyArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "legacy".write(to: legacyArtifact, atomically: true, encoding: .utf8)
    let runner = RecordingRunner(contents: "generated")

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-legacy-collision",
        generationID: "generation-legacy-collision"
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    #expect(await runner.invocationCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL().path))
    #expect(try String(contentsOf: legacyArtifact, encoding: .utf8) == "legacy")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    #expect(try await store.publishedArtifactsByTarget().isEmpty)
  }

  @Test(arguments: [
    ".privateheaderkit-generation.json/opaque.txt",
    ".PRIVATEHEADERKIT-GENERATION.JSON",
  ])
  func freshLegacyReservedMarkerCollisionFailsBeforeRunningTarget(
    _ legacyPath: String
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let legacyArtifact = fixture.stableURL.appendingPathComponent(legacyPath)
    try FileManager.default.createDirectory(
      at: legacyArtifact.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "legacy".write(to: legacyArtifact, atomically: true, encoding: .utf8)
    let runner = RecordingRunner(contents: "generated")

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-reserved-marker",
        generationID: "generation-reserved-marker"
      ).run(plan: try fixture.plan(.query("Foo"), resumeBehavior: .fresh))
    }

    #expect(await runner.invocationCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL().path))
    #expect(try String(contentsOf: legacyArtifact, encoding: .utf8) == "legacy")
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL,
      toolCompatibilityIdentity: "test"
    )
    #expect(try await store.publishedArtifactsByTarget().isEmpty)
  }

  @Test func startupRecoveryRemovesCrashedStateStagingPayload() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let crashed = fixture.stateDirectory.appendingPathComponent(
      "staging/run-crashed", isDirectory: true)
    try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: crashed.appendingPathComponent("payload"))

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: try fixture.plan(.query("Foo")))

    #expect(!FileManager.default.fileExists(atPath: crashed.path))
  }

  @Test func hiddenRawPayloadFailsFastWithoutPublishing() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: "generated", writesHiddenPayload: true)

    do {
      _ = try await fixture.executor(
        runner: runner,
        runID: "run-hidden",
        generationID: "generation-hidden"
      ).run(plan: try fixture.plan(.query("Foo")))
      Issue.record("hidden raw payload unexpectedly succeeded")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.status == .failed)
      #expect(failure.summary.targetCounts.failed == 1)
      #expect(failure.message.contains("hidden staging payload"))
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
    let store = try GenerationStore(
      databaseURL: fixture.databaseURL, toolCompatibilityIdentity: "test")
    #expect(try await store.runSnapshot(.init(rawValue: "run-hidden")).status == .failed)
  }

  @Test func canonicalOutputAliasSharesResumeIdentityAndDatabase() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try FileManager.default.createDirectory(
      at: fixture.outputBase, withIntermediateDirectories: true)
    let alias = fixture.root.appendingPathComponent("OutputAlias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.outputBase)
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(plan: try fixture.plan(.query("Foo"), outputBase: alias))
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(plan: try fixture.plan(.query("Foo")))

    #expect(await secondRunner.invocationCount == 0)
    #expect(result.artifactDirectory == fixture.liveURL)
    #expect(result.stateDatabaseURL == fixture.databaseURL)
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func bundleLayoutPublishesFrameworkBundlePath() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "bundle"),
      runID: "run-bundle",
      generationID: "generation-bundle"
    ).run(plan: try fixture.plan(.query("Foo"), layout: .bundle))

    let url = fixture.stableURL.appendingPathComponent(
      "Frameworks/Foo.framework/Headers/Generated.h")
    #expect(try String(contentsOf: url, encoding: .utf8) == "bundle")
  }

  @Test func headersLayoutKeepsSiblingBundleNamespacesDistinct() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createSystemBundle("CoreServices/Siri.app")
    try fixture.createSystemBundle("CoreServices/Siri.bundle")
    let runner = RecordingRunner(contents: "generated")
    let targetIDs = [
      "system-library:CoreServices/Siri.app",
      "system-library:CoreServices/Siri.bundle",
    ]

    let result = try await fixture.executor(
      runner: runner,
      runID: "run-sibling-bundles",
      generationID: "generation-sibling-bundles"
    ).run(plan: try fixture.plan(.identifiers(targetIDs)))

    #expect(await runner.invocationCount == 2)
    #expect(result.targetCounts.completed == 2)
    #expect(result.generatedTargets.map(\.identifier) == targetIDs)
    for bundle in ["Siri.app", "Siri.bundle"] {
      let header = fixture.stableURL.appendingPathComponent(
        "SystemLibrary/CoreServices/\(bundle)/Headers/Generated.h"
      )
      #expect(try String(contentsOf: header, encoding: .utf8) == "generated")
    }
  }

  @Test func parentShellQueryRunsEligibleNestedChildrenOnly() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createResourceOnlyFramework(
      "Shell.framework",
      nestedBundle: "XPCServices/LiveService.xpc"
    )
    let runner = RecordingRunner(contents: "nested")

    let result = try await fixture.executor(
      runner: runner,
      runID: "run-shell-child",
      generationID: "generation-shell-child"
    ).run(plan: try fixture.plan(.query("Shell")))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == [
      "nested-bundle:Frameworks/Shell.framework/XPCServices/LiveService.xpc"
    ])
    let invocations = await runner.invocations
    let invocation = try #require(invocations.first)
    #expect(invocation.inputPath.hasSuffix("/Shell.framework/XPCServices/LiveService.xpc"))
  }

  @Test func selectionOnlyParentIdentifierIsNotAnExecutionTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createResourceOnlyFramework(
      "Shell.framework",
      nestedBundle: "XPCServices/LiveService.xpc"
    )

    await #expect(
      throws: PrivateHeaderGeneration.GenerationError.unknownSelectedTargets([
        "framework:Shell.framework"
      ])
    ) {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "unused"),
        runID: "run-parent-identifier",
        generationID: "generation-parent-identifier"
      ).run(plan: try fixture.plan(.identifiers(["framework:Shell.framework"])))
    }
  }

  @Test func exactNestedIdentifierRunsOnlyThatExecutionTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createResourceOnlyFramework(
      "Shell.framework",
      nestedBundle: "XPCServices/LiveService.xpc"
    )
    let childID = "nested-bundle:Frameworks/Shell.framework/XPCServices/LiveService.xpc"
    let runner = RecordingRunner(contents: "nested")

    let result = try await fixture.executor(
      runner: runner,
      runID: "run-child-identifier",
      generationID: "generation-child-identifier"
    ).run(plan: try fixture.plan(.identifiers([childID])))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == [childID])
  }

  @Test func committedRunStaysSuccessfulWhenCleanupAndWarningPersistenceFail() async throws {
    let fixture = try ExecutorFixture()
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: fixture.stateDirectory.appendingPathComponent("staging").path
      )
      fixture.cleanup()
    }
    try fixture.createFramework("Foo.framework")
    let progress = ExecutorProgressRecorder()
    let stagingParent = fixture.stateDirectory.appendingPathComponent("staging", isDirectory: true)

    let result = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-warning",
      generationID: "generation-warning",
      storeFaultInjector: { point in
        if point == .beforeRunLogWrite { throw InjectedFault.stop }
      }
    ).run(
      plan: try fixture.plan(.query("Foo")),
      progressReporter: { event in
        progress.record(event)
        switch event {
        case .targetFinished:
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: stagingParent.path
          )
        case .warning:
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stagingParent.path
          )
        default:
          break
        }
      })

    let warning = try #require(result.warnings.first)
    #expect(warning.kind == "cleanup-warning")
    #expect(warning.message.contains("additionally failed to persist warning"))
    #expect(try fixture.readStableHeader() == "generated")
    let summaries: [PrivateHeaderGeneration.RunSummary] = progress.events.compactMap { event in
      guard case .runFinished(let summary) = event else { return nil }
      return summary
    }
    #expect(summaries.last?.status == .completed)
    #expect(summaries.last?.warnings == result.warnings)
  }
}

private final class ExecutorProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [PrivateHeaderGeneration.ProgressEvent] = []

  var events: [PrivateHeaderGeneration.ProgressEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func record(_ event: PrivateHeaderGeneration.ProgressEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }
}

private final class FileMutationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMessage: String?

  var message: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedMessage
  }

  func run(_ operation: () throws -> Void) {
    do {
      try operation()
    } catch {
      lock.lock()
      storedMessage = String(describing: error)
      lock.unlock()
    }
  }
}

private final class LiveArtifactObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var storedContents: String?
  private var storedErrorDescription: String?

  var contents: String? {
    lock.withLock { storedContents }
  }

  var errorDescription: String? {
    lock.withLock { storedErrorDescription }
  }

  func observe(_ url: URL) {
    lock.withLock {
      do {
        storedContents = try String(contentsOf: url, encoding: .utf8)
      } catch {
        storedErrorDescription = String(describing: error)
      }
    }
  }
}

private func captureInterruption(
  operation: @escaping @Sendable () async throws -> PrivateHeaderGeneration.Result
) async -> PrivateHeaderGeneration.RunInterruption? {
  await Task {
    do {
      _ = try await operation()
      Issue.record("cancelled operation unexpectedly returned success")
      return nil
    } catch let PrivateHeaderGeneration.GenerationError.runInterrupted(interruption) {
      return interruption
    } catch {
      Issue.record("cancelled operation returned unexpected error: \(error)")
      return nil
    }
  }.value
}

private actor RecordingRunner {
  private(set) var invocations: [PrivateHeaderGeneration.RawDumping.Invocation] = []
  let contents: String?
  let result: PrivateHeaderGeneration.RawDumping.Result
  let thrownError: (any Error & Sendable)?
  let writesHiddenPayload: Bool
  let hiddenPayloadFramework: String?
  let primaryHeaderName: String
  let additionalHeaderName: String?
  let cancelsForFramework: String?
  let afterRun: @Sendable () -> Void

  init(
    contents: String?,
    result: PrivateHeaderGeneration.RawDumping.Result = .init(terminationStatus: 0),
    thrownError: (any Error & Sendable)? = nil,
    writesHiddenPayload: Bool = false,
    hiddenPayloadFramework: String? = nil,
    primaryHeaderName: String = "Generated.h",
    additionalHeaderName: String? = nil,
    cancelsForFramework: String? = nil,
    afterRun: @escaping @Sendable () -> Void = {}
  ) {
    self.contents = contents
    self.result = result
    self.thrownError = thrownError
    self.writesHiddenPayload = writesHiddenPayload
    self.hiddenPayloadFramework = hiddenPayloadFramework
    self.primaryHeaderName = primaryHeaderName
    self.additionalHeaderName = additionalHeaderName
    self.cancelsForFramework = cancelsForFramework
    self.afterRun = afterRun
  }

  var invocationCount: Int { invocations.count }

  func run(_ invocation: PrivateHeaderGeneration.RawDumping.Invocation) throws
    -> PrivateHeaderGeneration.RawDumping.Result
  {
    invocations.append(invocation)
    if let thrownError { throw thrownError }
    if let cancelsForFramework, invocation.inputPath.hasSuffix("/\(cancelsForFramework)") {
      throw CancellationError()
    }
    if let contents {
      let output = outputDirectory(for: invocation)
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try Data(contents.utf8).write(to: output.appendingPathComponent(primaryHeaderName))
      if let additionalHeaderName {
        try Data(contents.utf8).write(to: output.appendingPathComponent(additionalHeaderName))
      }
      if writesHiddenPayload
        || hiddenPayloadFramework.map({ invocation.inputPath.hasSuffix("/\($0)") }) == true
      {
        try Data("hidden".utf8).write(
          to: invocation.stagingOutputDirectory.appendingPathComponent(".unexpected")
        )
      }
    }
    afterRun()
    return result
  }

  private func outputDirectory(for invocation: PrivateHeaderGeneration.RawDumping.Invocation) -> URL
  {
    let marker = "/System/Library/"
    guard let range = invocation.inputPath.range(of: marker) else {
      return invocation.stagingOutputDirectory.appendingPathComponent("Headers", isDirectory: true)
    }
    var output = invocation.stagingOutputDirectory
    for component in invocation.inputPath[range.lowerBound...]
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .split(separator: "/")
    {
      output.appendPathComponent(String(component), isDirectory: true)
    }
    return output.appendingPathComponent("Headers", isDirectory: true)
  }
}

private actor RecordingInventoryRunner {
  private var data: Data
  private(set) var invocations:
    [PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation] = []

  init(data: Data) {
    self.data = data
  }

  var invocationCount: Int { invocations.count }

  func replaceData(_ data: Data) {
    self.data = data
  }

  func run(
    _ invocation: PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation
  ) throws -> Data {
    invocations.append(invocation)
    return data
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate func run(
    plan: PrivateHeaderGeneration.Plan,
    progressReporter: ProgressReporter? = nil
  ) async throws -> PrivateHeaderGeneration.Result {
    let preparedPlan = try await prepare(plan)
    return try await run(preparedPlan, progressReporter: progressReporter)
  }
}

private struct ExecutorFixture {
  let root: URL
  let systemRoot: URL
  let outputBase: URL
  let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs
  let source: PrivateHeaderGeneration.Source

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrivateHeaderGenerationExecutorTests-\(UUID().uuidString)",
      isDirectory: true
    )
    systemRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
    outputBase = root.appendingPathComponent("Output", isDirectory: true)
    helperURLs = .init(
      host: root.appendingPathComponent("bin/privateheaderkit"),
      simulator: root.appendingPathComponent("bin/privateheaderkit-sim")
    )
    source = try PrivateHeaderGeneration.Source(
      platform: .macOS,
      version: "16.0",
      build: "25A000"
    )
    try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
  }

  var sourceLabel: String { source.storageIdentifier }
  var stableURL: URL { outputBase.appendingPathComponent(sourceLabel, isDirectory: false) }
  var liveURL: URL {
    outputBase.appendingPathComponent(
      "generated-headers/\(sourceLabel)",
      isDirectory: true
    )
  }
  var stateDirectory: URL {
    outputBase.appendingPathComponent(".state/\(sourceLabel)", isDirectory: true)
  }
  var databaseURL: URL { stateDirectory.appendingPathComponent("generation.sqlite") }

  func stagedHeaderURL(runID: String, framework: String) -> URL {
    stateDirectory
      .appendingPathComponent("staging/\(runID)", isDirectory: true)
      .appendingPathComponent("framework%3A\(framework).framework", isDirectory: true)
      .appendingPathComponent(
        "System/Library/Frameworks/\(framework).framework/Headers/Generated.h"
      )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func removeDatabaseFiles() throws {
    for suffix in ["", "-shm", "-wal"] {
      let url = URL(fileURLWithPath: databaseURL.path + suffix)
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    }
  }

  func createFramework(_ name: String) throws {
    let bundleURL = systemRoot.appendingPathComponent(
      "System/Library/Frameworks/\(name)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    let executableName = bundleURL.deletingPathExtension().lastPathComponent
    try Data().write(to: bundleURL.appendingPathComponent(executableName, isDirectory: false))
  }

  func createSystemBundle(_ relativePath: String) throws {
    let bundleURL = systemRoot.appendingPathComponent(
      "System/Library/\(relativePath)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: bundleURL,
      withIntermediateDirectories: true
    )
    let executableName = bundleURL.deletingPathExtension().lastPathComponent
    try Data().write(to: bundleURL.appendingPathComponent(executableName, isDirectory: false))
  }

  func createResourceOnlyFramework(
    _ name: String,
    nestedBundle relativeNestedBundlePath: String
  ) throws {
    let frameworkURL = systemRoot.appendingPathComponent(
      "System/Library/Frameworks/\(name)",
      isDirectory: true
    )
    let nestedBundleURL = frameworkURL.appendingPathComponent(
      relativeNestedBundlePath,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: nestedBundleURL,
      withIntermediateDirectories: true
    )
    let executableName = nestedBundleURL.deletingPathExtension().lastPathComponent
    try Data().write(
      to: nestedBundleURL.appendingPathComponent(executableName, isDirectory: false)
    )
  }

  func plan(
    _ targetRequest: PrivateHeaderGeneration.TargetRequest,
    layout: PrivateHeaderGeneration.Layout = .headers,
    resumeBehavior: PrivateHeaderGeneration.ResumeBehavior = .requireExplicitResume(
      resumeRequested: false),
    outputBase: URL? = nil,
    rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options = .init()
  ) throws -> PrivateHeaderGeneration.Plan {
    return PrivateHeaderGeneration.makePlan(
      source: source,
      output: .init(baseDirectory: outputBase ?? self.outputBase),
      options: .init(
        layout: layout,
        targetRequest: targetRequest,
        systemRoot: systemRoot,
        helperURLs: helperURLs,
        executionMode: .host,
        rawDumpingOptions: rawDumpingOptions,
        resumeBehavior: resumeBehavior,
        toolCompatibilityIdentity: "test"
      )
    )
  }

  func executor(
    runner: RecordingRunner,
    inventoryRunner:
      @escaping PrivateHeaderGeneration.GenerationExecutor.SharedCacheInventoryRunner = { _ in
        throw ExecutorFixtureError.unexpectedSharedCacheInventory
      },
    runID: String,
    generationID: String,
    storeFaultInjector: @escaping GenerationStore.FaultInjector = { _ in },
    publicationFaultInjector:
      @escaping PrivateHeaderGeneration.GenerationExecutor.PublicationFaultInjector = { _ in }
  ) -> PrivateHeaderGeneration.GenerationExecutor {
    .init(
      rawDumpRunner: { invocation in try await runner.run(invocation) },
      sharedCacheInventoryRunner: inventoryRunner,
      runIDGenerator: { runID },
      generationIDGenerator: { generationID },
      dateProvider: { Date(timeIntervalSinceReferenceDate: 100) },
      storeFaultInjector: storeFaultInjector,
      publicationFaultInjector: publicationFaultInjector
    )
  }

  func publisher() throws -> ArtifactPublisher {
    try ArtifactPublisher(artifactBaseDirectory: outputBase, sourceLabel: sourceLabel)
  }

  func stableHeaderURL(framework: String = "Foo") -> URL {
    stableURL.appendingPathComponent("Frameworks/\(framework)/Headers/Generated.h")
  }

  func liveHeaderURL(framework: String = "Foo") -> URL {
    liveURL.appendingPathComponent("Frameworks/\(framework)/Headers/Generated.h")
  }

  func readStableHeader(framework: String = "Foo") throws -> String {
    try String(contentsOf: stableHeaderURL(framework: framework), encoding: .utf8)
  }

  func readLiveHeader(framework: String = "Foo") throws -> String {
    try String(contentsOf: liveHeaderURL(framework: framework), encoding: .utf8)
  }
}

private func sharedCacheInventoryData(
  cacheUUID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
  imagePaths: [String]
) throws -> Data {
  try JSONEncoder().encode(
    PrivateHeaderKitSharedCacheInventory(
      cacheUUID: cacheUUID,
      imagePaths: imagePaths
    )
  )
}
