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
    case rawFailure
  }

  @Test(arguments: ["Generated.h", "Generated.swiftinterface"])
  func artifactSummaryCountsOnlyFilesPublishedByThisInvocation(_ primaryFile: String) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Old.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old", additionalHeaderName: "Old.h"),
      runID: "old-run"
    ).run(plan: fixture.plan(.query("Old")))

    try fixture.createFramework("Foo.framework")
    let result = try await fixture.executor(
      runner: RecordingRunner(
        contents: "generated", primaryHeaderName: primaryFile, additionalHeaderName: "Foo.symbols.tsv"
      ),
      runID: "new-run"
    ).run(plan: fixture.plan(.query("Foo")))

    #expect(result.artifactCounts.objectiveCHeaders == (primaryFile == "Generated.h" ? 1 : 0))
    #expect(result.artifactCounts.swiftInterfaces == (primaryFile == "Generated.swiftinterface" ? 1 : 0))
    #expect(result.artifactCounts.symbolLists == 1)
    #expect(result.summary.artifactCounts == result.artifactCounts)
    #expect(result.summary.status == .completed)
    #expect(try fixture.readLiveHeader(framework: "Old") == "old")
  }

  @Test func namedTargetsRegenerateWithoutContinuationFlagsAfterProducerChange() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    for (index, version) in ["v1", "v2", "v2"].enumerated() {
      let runner = RecordingRunner(
        contents: "run-\(index)",
        result: .init(
          terminationStatus: 0,
          diagnosticsReport: .init(producerVersion: version, diagnostics: [])
        )
      )
      let executor = fixture.executor(
        runner: runner, runID: "run-\(index)"
      )
      let plan = try fixture.plan(
        index == 0 ? .allAvailable : .query("Foo"), producerVersion: version
      )
      let prepared = try await executor.prepare(plan)
      #expect(try await executor.availableResumeSummary(for: prepared) == nil)
      let result = try await executor.run(prepared)
      #expect(await runner.invocationCount == 1)
      #expect(result.targetCounts.completed == 1)
      #expect(try fixture.readLiveHeader() == "run-\(index)")
    }
  }

  @Test func targetedGenerationPreservesInterruptedAllTargetProgress() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Alpha.framework")
    try fixture.createFramework("Zulu.framework")
    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "batch", cancelsForFramework: "Zulu.framework"),
        runID: "run-batch"
      ).run(plan: fixture.plan(.allAvailable))
      Issue.record("expected interruption")
    } catch PrivateHeaderGeneration.GenerationError.runInterrupted(let interruption) {
      #expect(interruption.summary.targetCounts.completed == 1)
    }
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "targeted", additionalHeaderName: "Additional.h"),
      runID: "run-targeted"
    ).run(plan: fixture.plan(.query("Alpha")))
    let runner = RecordingRunner(contents: "resumed")
    let executor = fixture.executor(
      runner: runner, runID: "run-resumed"
    )
    let prepared = try await executor.prepare(fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume)))
    let summary = try #require(try await executor.availableResumeSummary(for: prepared))
    #expect(summary.latestRunID.rawValue == "run-batch")
    #expect(summary.counts.completed == 1)
    let result = try await executor.run(prepared)
    #expect(await runner.invocationCount == 1)
    #expect(await runner.invocations.first?.inputPath.hasSuffix("/Zulu.framework") == true)
    #expect(result.targetCounts.skipped == 1)
    #expect(result.artifactCounts.objectiveCHeaders == 1)
    #expect(try fixture.readLiveHeader(framework: "Alpha") == "targeted")
    #expect(try fixture.readLiveHeader(framework: "Zulu") == "resumed")
  }

  @Test(arguments: ["Bravo", "Charlie", "Delta"])
  func allTargetResumeReusesIndividualRepairsAndNewTargets(_ repairedTarget: String) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    for target in ["Alpha", "Bravo", "Charlie"] {
      try fixture.createFramework("\(target).framework")
    }
    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "batch", cancelsForFramework: "Bravo.framework"),
        runID: "run-batch"
      ).run(plan: fixture.plan(.allAvailable))
      Issue.record("expected interruption")
    } catch PrivateHeaderGeneration.GenerationError.runInterrupted(let interruption) {
      #expect(interruption.summary.targetCounts.completed == 1)
    }
    if repairedTarget == "Delta" { try fixture.createFramework("Delta.framework") }
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "repaired"),
      runID: "run-repaired"
    ).run(plan: fixture.plan(.query(repairedTarget)))
    let runner = RecordingRunner(contents: "resumed")
    let result = try await fixture.executor(
      runner: runner, runID: "run-resumed"
    ).run(plan: fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume)))
    #expect(await runner.invocationCount == (repairedTarget == "Delta" ? 2 : 1))
    #expect(result.targetCounts.skipped == 2)
    #expect(try fixture.readLiveHeader(framework: repairedTarget) == "repaired")
  }

  @Test func completedAllTargetRunRegeneratesUnlessResumeIsRequested() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    for index in 0..<2 {
      let runner = RecordingRunner(contents: "run-\(index)")
      let result = try await fixture.executor(
        runner: runner, runID: "run-\(index)"
      ).run(plan: fixture.plan(.allAvailable))
      #expect(await runner.invocationCount == 1)
      #expect(result.targetCounts.completed == 1)
    }
  }

  @Test(arguments: ["producer", "options", "targets"])
  func completedAllTargetRunStartsAgainAfterConfigurationChange(_ change: String) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    if change == "targets" { try fixture.createFramework("Bar.framework") }
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first", result: .init(
        terminationStatus: 0,
        diagnosticsReport: .init(producerVersion: "v1", diagnostics: [])
      )),
      runID: "run-first"
    ).run(plan: fixture.plan(.allAvailable, producerVersion: "v1"))
    if change == "targets" {
      try FileManager.default.removeItem(
        at: fixture.systemRoot.appendingPathComponent("System/Library/Frameworks/Bar.framework")
      )
    }
    let version = change == "producer" ? "v2" : "v1"
    let runner = RecordingRunner(contents: "regenerated", result: .init(
      terminationStatus: 0,
      diagnosticsReport: .init(producerVersion: version, diagnostics: [])
    ))
    let executor = fixture.executor(
      runner: runner, runID: "run-next"
    )
    let prepared = try await executor.prepare(fixture.plan(
      .allAvailable, rawDumpingOptions: .init(verbose: change == "options"),
      producerVersion: version
    ))
    #expect(try await executor.availableResumeSummary(for: prepared) == nil)
    let result = try await executor.run(prepared)
    #expect(await runner.invocationCount == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "regenerated")
  }

  @Test(arguments: [true, false])
  func changedProducerStillRejectsExplicitResumeOrUnfinishedWork(_ completed: Bool) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "first", result: .init(
          terminationStatus: completed ? 0 : 1,
          diagnosticsReport: .init(producerVersion: "v1", diagnostics: [])
        )),
        runID: "run-first"
      ).run(plan: fixture.plan(.allAvailable, producerVersion: "v1"))
      #expect(completed)
    } catch PrivateHeaderGeneration.GenerationError.runFailed {
      #expect(!completed)
    }
    let runner = RecordingRunner(contents: "must not run")
    let executor = fixture.executor(
      runner: runner, runID: "run-next"
    )
    let prepared = try await executor.prepare(fixture.plan(
      .allAvailable,
      executionOptions: .init(continuation: completed ? .resume : .automatic),
      producerVersion: "v2"
    ))
    let expected = PrivateHeaderGeneration.GenerationError.incompatibleResume("plan fingerprint changed")
    await #expect(throws: expected) { _ = try await executor.availableResumeSummary(for: prepared) }
    await #expect(throws: expected) { _ = try await executor.run(prepared) }
    #expect(await runner.invocationCount == 0)
  }

  @Test func individualRepairCanFinishAnOlderCheckpointBeforeNormalGeneration() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Alpha.framework")
    try fixture.createFramework("Zulu.framework")
    do {
      _ = try await fixture.executor(
        runner: RecordingRunner(contents: "original", cancelsForFramework: "Zulu.framework"),
        runID: "run-original"
      ).run(plan: fixture.plan(.allAvailable))
      Issue.record("expected interruption")
    } catch PrivateHeaderGeneration.GenerationError.runInterrupted {}
    let updatedResult = PrivateHeaderGeneration.RawDumping.Result(
      terminationStatus: 0,
      diagnosticsReport: .init(producerVersion: "updated", diagnostics: [])
    )
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "repaired", result: updatedResult),
      runID: "run-repair"
    ).run(plan: fixture.plan(.query("Zulu"), producerVersion: "updated"))
    let runner = RecordingRunner(contents: "new-batch", result: updatedResult)
    let executor = fixture.executor(
      runner: runner, runID: "run-new"
    )
    let prepared = try await executor.prepare(fixture.plan(.allAvailable, producerVersion: "updated"))
    #expect(try await executor.availableResumeSummary(for: prepared) == nil)
    let result = try await executor.run(prepared)
    #expect(result.targetCounts.completed == 2)
    #expect(await runner.invocationCount == 2)
  }

  @Test func compatibleResumeSkipsCurrentCompletedTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume))
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first"),
      runID: "run-001"
    ).run(plan: plan)
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002"
    ).run(plan: plan)

    #expect(await secondRunner.invocationCount == 0)
    #expect(result.generatedTargets.isEmpty)
    #expect(result.targetCounts.skipped == 1)
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
      runID: "run-001"
    ).run(plan: try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume), outputBase: alias))
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002"
    ).run(plan: try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume)))

    #expect(await secondRunner.invocationCount == 0)
    #expect(result.artifactDirectory == fixture.liveURL)
    #expect(result.stateDatabaseURL == fixture.databaseURL)
  }

  @Test func unresolvedQueryPreservesMissingTermsAndCandidatePaths() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("FooOne.framework")
    try fixture.createFramework("FooTwo.framework")
    let runner = RecordingRunner(contents: "must not run")
    let executor = fixture.executor(
      runner: runner, runID: "run-unresolved"
    )
    do {
      _ = try await executor.prepare(fixture.plan(.query("Foo,Missing")))
      Issue.record("expected unresolved selection")
    } catch let error as PrivateHeaderGeneration.GenerationError {
      guard case .unresolvedTargetQuery(.unresolved(let ambiguities, let failures)) = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(failures.map(\.query) == ["Missing"])
      #expect(ambiguities.map(\.query) == ["Foo"])
      #expect(ambiguities.first?.candidates.map(\.displayName) == ["FooOne", "FooTwo"])
      #expect(error.description.contains("no target matches \"Missing\""))
      #expect(error.description.contains("/System/Library/Frameworks/FooOne.framework"))
      #expect(error.description.contains("/System/Library/Frameworks/FooTwo.framework"))
    }
    #expect(await runner.invocationCount == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
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
      runID: "run-cache"
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
      runID: "run-no-cache"
    )

    let preparedPlan = try await executor.prepare(try fixture.plan(.query("Foo")))
    _ = try await executor.run(preparedPlan)

    #expect(await inventoryRunner.invocationCount == 0)
    #expect(preparedPlan.sharedCacheCohort == nil)
  }

  @Test func inventoryProducerVersionMismatchFailsDuringPreparation() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let inventoryRunner = RecordingInventoryRunner(
      data: try sharedCacheInventoryData(
        producerVersion: "v0.9.0",
        imagePaths: ["/System/Library/Frameworks/Foo.framework/Foo"]
      )
    )
    let executor = fixture.executor(
      runner: RecordingRunner(contents: "must-not-run"),
      inventoryRunner: { invocation in try await inventoryRunner.run(invocation) },
      runID: "run-unused"
    )

    await #expect(
      throws: PrivateHeaderGeneration.GenerationError.producerVersionMismatch(
        expected: "v1.0.0",
        actual: "v0.9.0"
      )
    ) {
      _ = try await executor.prepare(
        try fixture.plan(
          .query("Foo"),
          rawDumpingOptions: .init(useSharedCache: true),
          producerVersion: "v1.0.0"
        )
      )
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.outputBase.path))
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
      runID: "run-cache-change"
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

  @Test func preparedPlanCanChangeOnlyInteractiveExecutionOptionsWithoutReloadingCohort() async throws
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
      runID: "run-unused"
    )
    let preparedPlan = try await executor.prepare(
      try fixture.plan(
        .query("Foo"),
        rawDumpingOptions: .init(useSharedCache: true)
      )
    )

    let resumedPlan = preparedPlan.withExecutionOptions(.init(continuation: .resume))

    #expect(resumedPlan.plan.options.executionOptions == .init(continuation: .resume))
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
      runID: "run-unused-1"
    )
    let reorderedExecutor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in
        try sharedCacheInventoryData(
          cacheUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
          imagePaths: ["/a", "/z", "/a"]
        )
      },
      runID: "run-unused-2"
    )
    let changedExecutor = fixture.executor(
      runner: RecordingRunner(contents: nil),
      inventoryRunner: { _ in
        try sharedCacheInventoryData(
          cacheUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
          imagePaths: ["/a", "/z"]
        )
      },
      runID: "run-unused-3"
    )
    let first = try await firstExecutor.prepare(plan)
    let reordered = try await reorderedExecutor.prepare(plan)
    let changed = try await changedExecutor.prepare(plan)

    let firstFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
      executionMode: .host,
      sharedCacheCohort: first.sharedCacheCohort
    )
    let reorderedFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
      executionMode: .host,
      sharedCacheCohort: reordered.sharedCacheCohort
    )
    let changedFingerprint = PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
      plan,
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
      runID: "run-unused"
    )
    let plan = try fixture.plan(
      .query("Foo"),
      rawDumpingOptions: .init(useSharedCache: true)
    )

    await #expect(throws: PrivateHeaderGeneration.GenerationError.self) {
      _ = try await executor.prepare(plan)
    }
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
      runID: "run-objc-warning"
    )

    let result = try await executor.run(plan: try fixture.plan(.query("Foo")))

    #expect(result.targetCounts.completed == 1)
    #expect(result.warnings.count == 3)
    #expect(result.warnings.allSatisfy { $0.kind == "objc-metadata-warning" })
    #expect(result.warnings.map(\.message) == result.warnings.map(\.message).sorted())
    #expect(try fixture.readLiveHeader() == "generated")
    let persisted = try await DatabaseQueue(path: fixture.databaseURL.path).read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT kind, relativePath, message FROM runLogs WHERE runID = ? ORDER BY message",
        arguments: [result.runID.rawValue]
      ).map { row in
        (
          kind: row["kind"] as String,
          message: row["message"] as String
        )
      }
    }
    #expect(persisted.count == result.warnings.count)
    #expect(persisted.map(\.kind) == result.warnings.map(\.kind))
    #expect(persisted.map(\.message) == result.warnings.map(\.message))
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
      runID: "run-objc-failure"
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
      runID: "run-objc-budget"
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

  @Test func completedTargetIsVisibleWhenItsFinishedEventIsReported() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let observation = LiveArtifactObservation()

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-visible"
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

  @Test func runRemovesStagingLeftByATerminatedRun() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let crashed = fixture.stateDirectory.appendingPathComponent(
      "staging/run-crashed", isDirectory: true)
    try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: crashed.appendingPathComponent("payload"))

    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "generated"),
      runID: "run-001"
    ).run(plan: try fixture.plan(.query("Foo")))

    #expect(!FileManager.default.fileExists(atPath: crashed.path))
  }

  @Test func bundleLayoutPublishesFrameworkBundlePath() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "bundle"),
      runID: "run-bundle"
    ).run(plan: try fixture.plan(.query("Foo"), layout: .bundle))

    let url = fixture.liveURL.appendingPathComponent(
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
      runID: "run-sibling-bundles"
    ).run(plan: try fixture.plan(.identifiers(targetIDs)))

    #expect(await runner.invocationCount == 2)
    #expect(result.targetCounts.completed == 2)
    #expect(result.generatedTargets.map(\.identifier) == targetIDs)
    for bundle in ["Siri.app", "Siri.bundle"] {
      let header = fixture.liveURL.appendingPathComponent(
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
      runID: "run-shell-child"
    ).run(plan: try fixture.plan(.query("Shell")))

    #expect(await runner.invocationCount == 1)
    #expect(
      result.generatedTargets.map(\.identifier) == [
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
        runID: "run-parent-identifier"
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
      runID: "run-child-identifier"
    ).run(plan: try fixture.plan(.identifiers([childID])))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == [childID])
  }

  @Test func successfulRunPublishesHeadersAndCompletesTheRun() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: "first")

    let result = try await fixture.executor(runner: runner, runID: "run-001")
      .run(plan: try fixture.plan(.query("Foo")))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == ["framework:Foo.framework"])
    #expect(result.targetCounts.completed == 1)
    #expect(result.warnings.isEmpty)
    #expect(result.artifactDirectory == fixture.liveURL)
    #expect(result.stateDatabaseURL == fixture.databaseURL)
    #expect(try fixture.readLiveHeader() == "first")
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.stateDirectory.appendingPathComponent("staging").path
      )
    )
    #expect(try await fixture.latestRun().status == .completed)
    #expect(
      try await fixture.store().publishedArtifacts(targetID: "framework:Foo.framework")
        == [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Headers/Generated.h")]
    )
  }

  @Test func regenerationRemovesFilesTheTargetNoLongerProduces() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createResourceOnlyFramework(
      "Foo.framework", nestedBundle: "XPCServices/Service.xpc"
    )
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "first", additionalHeaderName: "Removed.h"),
      runID: "run-first"
    ).run(plan: try fixture.plan(.query("Foo")))
    let headers = fixture.liveHeaderURL().deletingLastPathComponent()
    let nestedHeader = fixture.liveURL.appendingPathComponent(
      "Frameworks/Foo/XPCServices/Service.xpc/Headers/Generated.h"
    )
    #expect(FileManager.default.fileExists(atPath: headers.appendingPathComponent("Removed.h").path))
    #expect(try String(contentsOf: nestedHeader, encoding: .utf8) == "first")

    _ = try await fixture.executor(runner: RecordingRunner(contents: "second"), runID: "run-second")
      .run(plan: try fixture.plan(.identifiers(["framework:Foo.framework"])))

    #expect(try FileManager.default.contentsOfDirectory(atPath: headers.path) == ["Generated.h"])
    #expect(try fixture.readLiveHeader() == "second")
    #expect(try String(contentsOf: nestedHeader, encoding: .utf8) == "first")
  }

  @Test func generationRemovesFilesLeftByAnAttemptThatStoppedWhilePublishing() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let leftover = try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Headers/Leftover.h")
    let leftoverURL = fixture.liveURL.appendingPathComponent(leftover.rawValue)
    try FileManager.default.createDirectory(
      at: leftoverURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("leftover".utf8).write(to: leftoverURL)
    let terminatedRunID = PrivateHeaderGeneration.RunID(rawValue: "run-terminated")
    let store = try fixture.store()
    try await store.beginRun(
      id: terminatedRunID,
      plan: .init(
        sourceIdentity: fixture.sourceLabel, fingerprint: "fingerprint",
        targetIDs: ["framework:Foo.framework"]
      ),
      at: Date(timeIntervalSinceReferenceDate: 50)
    )
    try await store.recordArtifactsBeingPublished(
      [leftover], targetID: "framework:Foo.framework", in: terminatedRunID
    )

    _ = try await fixture.executor(runner: RecordingRunner(contents: "generated"), runID: "run-next")
      .run(plan: try fixture.plan(.query("Foo")))

    #expect(!FileManager.default.fileExists(atPath: leftoverURL.path))
    #expect(try fixture.readLiveHeader() == "generated")
  }

  @Test func generationOverwritesHeadersThatOutlivedTheStateDatabase() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume))
    _ = try await fixture.executor(runner: RecordingRunner(contents: "first"), runID: "run-first")
      .run(plan: plan)
    try FileManager.default.removeItem(at: fixture.stateDirectory)
    let runner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(runner: runner, runID: "run-second").run(plan: plan)

    #expect(await runner.invocationCount == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "second")
  }

  @Test func symbolOnlyTargetsPublishAndResumeLikeHeaders() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let content = "# image\t/Foo\nvisibility\tname\tdemangled_name\nexport\t_Foo\t_Foo\n"
    let plan = try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume))
    let first = try await fixture.executor(
      runner: RecordingRunner(contents: content, primaryHeaderName: "Foo.symbols.tsv"),
      runID: "symbols-one"
    ).run(plan: plan)
    #expect(first.summary.status == .completed)
    #expect(first.artifactCounts.objectiveCHeaders == 0)
    #expect(first.artifactCounts.swiftInterfaces == 0)
    #expect(first.artifactCounts.symbolLists == 1)
    let file = fixture.liveHeaderURL().deletingLastPathComponent()
      .appendingPathComponent("Foo.symbols.tsv")
    #expect(try String(contentsOf: file, encoding: .utf8) == content)

    let nextRunner = RecordingRunner(
      contents: "must not regenerate", primaryHeaderName: "Foo.symbols.tsv"
    )
    let resumed = try await fixture.executor(runner: nextRunner, runID: "symbols-two")
      .run(plan: plan)
    #expect(resumed.targetCounts.skipped == 1)
    #expect(resumed.artifactCounts == .init(artifacts: []))
    #expect(await nextRunner.invocationCount == 0)
    #expect(try String(contentsOf: file, encoding: .utf8) == content)
  }

  @Test func resumeRegeneratesCompletedTargetWhosePublishedFilesWereDeleted() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let plan = try fixture.plan(.allAvailable, executionOptions: .init(continuation: .resume))
    _ = try await fixture.executor(runner: RecordingRunner(contents: "first"), runID: "run-first")
      .run(plan: plan)
    try FileManager.default.removeItem(at: fixture.liveURL)
    let runner = RecordingRunner(contents: "regenerated")
    let executor = fixture.executor(runner: runner, runID: "run-resumed")
    let preparedPlan = try await executor.prepare(plan)

    let summary = try #require(try await executor.availableResumeSummary(for: preparedPlan))
    #expect(summary.targets == [.init(targetID: "framework:Foo.framework", status: .pending)])

    let result = try await executor.run(preparedPlan)

    #expect(await runner.invocationCount == 1)
    #expect(result.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "regenerated")
  }

  @Test(arguments: [PrivateHeaderGeneration.Continuation.automatic, .resume, .restart])
  func runInterruptedAfterItsLastPublicationLeavesNothingToResume(
    _ continuation: PrivateHeaderGeneration.Continuation
  ) async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let interruption = await captureInterruption {
      try await fixture.executor(runner: RecordingRunner(contents: "published"), runID: "run-interrupted")
        .run(
          plan: fixture.plan(.allAvailable),
          progressReporter: { event in
            if case .targetFinished = event { withUnsafeCurrentTask { $0?.cancel() } }
          }
        )
    }
    let interrupted = try #require(interruption)
    #expect(interrupted.summary.status == .interrupted)
    #expect(interrupted.summary.targetCounts.completed == 1)
    #expect(try fixture.readLiveHeader() == "published")

    let runner = RecordingRunner(contents: "next")
    let executor = fixture.executor(runner: runner, runID: "run-next")
    let prepared = try await executor.prepare(
      fixture.plan(.allAvailable, executionOptions: .init(continuation: continuation))
    )
    #expect(try await executor.availableResumeSummary(for: prepared) == nil)
    let result = try await executor.run(prepared)
    #expect(await runner.invocationCount == (continuation == .resume ? 0 : 1))
    #expect(result.targetCounts.skipped == (continuation == .resume ? 1 : 0))
    #expect(try fixture.readLiveHeader() == (continuation == .resume ? "published" : "next"))
  }

  @Test func targetFailureKeepsObjectiveCWarningPresentationBoundedAndAggregated()
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
        failingFramework: "Zeta.framework"
      ),
      runID: "run-objc-budget-failure"
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
      Issue.record("failing target unexpectedly completed")
      return
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
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

  @Test func failedTargetKeepsCompletedTargetsPublishedAndResumeRetriesOnlyTheFailure()
    async throws
  {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    try fixture.createFramework("Baz.framework")
    let plan = try fixture.plan(
      .allAvailable,
      executionOptions: .init(continuation: .resume)
    )
    let firstRunner = RecordingRunner(contents: "first-run", failingFramework: "Bar.framework")

    do {
      _ = try await fixture.executor(runner: firstRunner, runID: "run-one-failure").run(plan: plan)
      Issue.record("failing target unexpectedly completed")
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
      #expect(failure.summary.status == .partial)
      #expect(failure.summary.targetCounts.completed == 2)
      #expect(failure.summary.targetCounts.partial == 1)
      #expect(failure.summary.artifactCounts.objectiveCHeaders == 2)
      #expect(failure.summary.targetCounts.pending == 0)
      #expect(failure.summary.targetCounts.running == 0)
      #expect(failure.failedTargetIDs == ["framework:Bar.framework"])
      #expect(failure.summary.targetFailures.map(\.displayName) == ["Bar"])
      #expect(failure.summary.targetFailures.first?.message == "helper failed")
    }

    #expect(await firstRunner.invocationCount == 3)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "first-run")
    #expect(try fixture.readLiveHeader(framework: "Baz") == "first-run")
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Bar").path))

    let resumedRunner = RecordingRunner(contents: "resumed")
    let result = try await fixture.executor(runner: resumedRunner, runID: "run-resumed")
      .run(plan: plan)

    #expect(await resumedRunner.invocationCount == 1)
    #expect(await resumedRunner.invocations.first?.inputPath.hasSuffix("/Bar.framework") == true)
    #expect(result.targetCounts.skipped == 2)
    #expect(result.targetCounts.completed == 1)
    #expect(result.artifactCounts.objectiveCHeaders == 1)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "first-run")
    #expect(try fixture.readLiveHeader(framework: "Baz") == "first-run")
    #expect(try fixture.readLiveHeader(framework: "Bar") == "resumed")
  }

  @Test func failedAndPartialAttemptsKeepTheLastPublishedFiles() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(runner: RecordingRunner(contents: "old"), runID: "run-001")
      .run(plan: try fixture.plan(.query("Foo")))
    let partialRunner = RecordingRunner(
      contents: "unpublished",
      result: .init(terminationStatus: 7, failureSummary: "raw dump failed")
    )

    do {
      _ = try await fixture.executor(runner: partialRunner, runID: "run-002")
        .run(plan: try fixture.plan(.query("Foo"), executionOptions: .init(continuation: .restart)))
      Issue.record("partial run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
      #expect(failure.summary.runID == .init(rawValue: "run-002"))
      #expect(failure.summary.status == .partial)
      #expect(failure.summary.targetCounts.partial == 1)
      #expect(failure.summary.artifactCounts == .init(artifacts: []))
      #expect(failure.summary.artifactDirectory == fixture.liveURL)
      #expect(failure.summary.stateDatabaseURL == fixture.databaseURL)
      #expect(failure.failedTargetIDs == ["framework:Foo.framework"])
    }

    #expect(try fixture.readLiveHeader() == "old")
    #expect(try await fixture.latestRun().status == .partial)
  }

  @Test func rawHelperFailureCapsuleSurvivesPartialAndFailedPersistence() async throws {
    let capsule = [
      "exception prefix",
      "final diagnostic tail",
      "privateheaderkit raw helper error: capsule=v1 termination=child_signal(11) "
        + "wrapper_status=11 wrapper_killed=false "
        + "handshake=available helper=privateheaderkit-sim-helper "
        + "lc_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee pid=4242 "
        + "start_us=1700000000123456 termination_observed_us=1777000111222333",
    ].joined(separator: "\n")
    let cases: [(
      name: String,
      contents: String?,
      targetStatus: PrivateHeaderGeneration.RunTargetStatus,
      runStatus: PrivateHeaderGeneration.RunStatus
    )] = [
      ("partial", "partial header", .partial, .partial),
      ("failed", nil, .failed, .failed),
    ]

    for testCase in cases {
      let fixture = try ExecutorFixture()
      defer { fixture.cleanup() }
      try fixture.createFramework("Foo.framework")
      let executor = fixture.executor(
        runner: RecordingRunner(
          contents: testCase.contents,
          result: .init(terminationStatus: 11, failureSummary: capsule)
        ),
        runID: "run-capsule-\(testCase.name)"
      )

      do {
        _ = try await executor.run(plan: try fixture.plan(.query("Foo")))
        Issue.record("raw helper failure unexpectedly returned success")
      } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
        #expect(failure.summary.status == testCase.runStatus)
        #expect(failure.summary.targetFailures.count == 1)
        #expect(failure.summary.targetFailures.first?.status == testCase.targetStatus)
        #expect(failure.summary.targetFailures.first?.message == capsule)
      }

      let snapshot = try await fixture.latestRun()
      #expect(snapshot.status == testCase.runStatus)
      #expect(snapshot.targets.map(\.status) == [testCase.targetStatus])
      #expect(snapshot.targets.map(\.failureSummary) == [capsule])
    }
  }

  @Test func runWithoutAnySuccessfulTargetFails() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: nil, thrownError: InjectedFault.rawFailure)

    do {
      _ = try await fixture.executor(runner: runner, runID: "run-failed")
        .run(plan: try fixture.plan(.query("Foo")))
      Issue.record("failed run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
      #expect(failure.summary.status == .failed)
    }

    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL().path))
    #expect(try await fixture.latestRun().status == .failed)
  }

  @Test func producerVersionMismatchStopsTheRunBeforeAnotherTargetOrPublication() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let runner = RecordingRunner(
      contents: "generated",
      result: .init(
        terminationStatus: 0,
        diagnosticsReport: PrivateHeaderKitRawDumpDiagnosticsReport(
          producerVersion: "v0.9.0",
          diagnostics: []
        )
      )
    )

    do {
      _ = try await fixture.executor(runner: runner, runID: "run-producer-mismatch").run(
        plan: try fixture.plan(
          .identifiers(["framework:Foo.framework", "framework:Bar.framework"]),
          producerVersion: "v1.0.0"
        )
      )
      Issue.record("producer version mismatch unexpectedly completed")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.message.contains("expected v1.0.0, actual v0.9.0"))
      #expect(failure.summary.status == .failed)
    }

    #expect(await runner.invocationCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveURL.path))
    #expect(try await fixture.latestRun().status == .failed)
  }

  @Test func rawHelperContractFailureStopsTheRunBeforeAnotherTargetOrPublication() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    try fixture.createFramework("Bar.framework")
    let runner = RecordingRunner(
      contents: nil,
      thrownError: PrivateHeaderGeneration.RawDumping.ContractError.invalidDiagnosticsReport(
        path: "/tmp/diagnostics.json",
        reason: "unsupported schema"
      )
    )

    do {
      _ = try await fixture.executor(runner: runner, runID: "run-helper-contract-failure").run(
        plan: try fixture.plan(
          .identifiers(["framework:Foo.framework", "framework:Bar.framework"])
        )
      )
      Issue.record("raw helper contract failure unexpectedly completed")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.message.contains("unsupported schema"))
      #expect(failure.summary.status == .failed)
    }

    #expect(await runner.invocationCount == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveURL.path))
    #expect(try await fixture.latestRun().status == .failed)
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
      _ = try await fixture.executor(runner: runner, runID: "run-cancelled").run(
        plan: plan,
        progressReporter: { event in
          progress.record(event)
        })
      Issue.record("interrupted run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runInterrupted(interruption) {
      #expect(interruption.summary.status == .interrupted)
      #expect(interruption.summary.targetCounts.completed == 1)
      #expect(interruption.summary.targetCounts.interrupted == 1)
      #expect(interruption.summary.artifactCounts.objectiveCHeaders == 1)
    }

    #expect(await runner.invocationCount == 2)
    #expect(try fixture.readLiveHeader(framework: "Foo") == "generated")
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL(framework: "Bar").path))
    let run = try await fixture.latestRun()
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
    #expect(summary.artifactCounts.objectiveCHeaders == 1)
    #expect(summary.artifactDirectory == fixture.liveURL)
    #expect(summary.stateDatabaseURL == fixture.databaseURL)
  }

  @Test func cancellationRightAfterTheRawDumpDoesNotPublishTheTarget() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(
      contents: "unpublished",
      afterRun: { withUnsafeCurrentTask { $0?.cancel() } }
    )
    let plan = try fixture.plan(.query("Foo"))

    let capturedInterruption = await captureInterruption {
      try await fixture.executor(runner: runner, runID: "run-after-raw-cancel").run(plan: plan)
    }
    #expect(try #require(capturedInterruption).summary.targetCounts.interrupted == 1)
    #expect(!FileManager.default.fileExists(atPath: fixture.liveHeaderURL().path))
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
  let failingFramework: String?
  let primaryHeaderName: String
  let additionalHeaderName: String?
  let cancelsForFramework: String?
  let afterRun: @Sendable () -> Void

  init(
    contents: String?,
    result: PrivateHeaderGeneration.RawDumping.Result = .init(terminationStatus: 0),
    thrownError: (any Error & Sendable)? = nil,
    failingFramework: String? = nil,
    primaryHeaderName: String = "Generated.h",
    additionalHeaderName: String? = nil,
    cancelsForFramework: String? = nil,
    afterRun: @escaping @Sendable () -> Void = {}
  ) {
    self.contents = contents
    self.result = result
    self.thrownError = thrownError
    self.failingFramework = failingFramework
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
    }
    afterRun()
    if let failingFramework, invocation.inputPath.hasSuffix("/\(failingFramework)") {
      return .init(terminationStatus: 1, failureSummary: "helper failed")
    }
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
      build: "25A000",
      metadataIsSeed: false
    )
    try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
  }

  var sourceLabel: String { source.storageIdentifier }
  var liveURL: URL {
    PrivateHeaderGeneration.Output(baseDirectory: outputBase).artifactDirectory(for: source)
  }
  var stateDirectory: URL {
    outputBase.appendingPathComponent(".state/\(sourceLabel)", isDirectory: true)
  }
  var databaseURL: URL { stateDirectory.appendingPathComponent("generation.sqlite") }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func store() throws -> GenerationStore {
    try GenerationStore(databaseURL: databaseURL)
  }

  func latestRun() async throws -> PrivateHeaderGeneration.RunSnapshot {
    try #require(try await store().latestRunSnapshot())
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
    executionOptions: PrivateHeaderGeneration.ExecutionOptions = .init(),
    outputBase: URL? = nil,
    rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options = .init(),
    producerVersion: String = PrivateHeaderKitBuildInfo.version
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
        executionOptions: executionOptions,
        producerVersion: producerVersion
      )
    )
  }

  func executor(
    runner: RecordingRunner,
    inventoryRunner:
      @escaping PrivateHeaderGeneration.GenerationExecutor.SharedCacheInventoryRunner = { _ in
        throw ExecutorFixtureError.unexpectedSharedCacheInventory
      },
    runID: String
  ) -> PrivateHeaderGeneration.GenerationExecutor {
    .init(
      rawDumpRunner: { invocation in try await runner.run(invocation) },
      sharedCacheInventoryRunner: inventoryRunner,
      runIDGenerator: { runID },
      dateProvider: { Date(timeIntervalSinceReferenceDate: 100) }
    )
  }

  func liveHeaderURL(framework: String = "Foo") -> URL {
    liveURL.appendingPathComponent("Frameworks/\(framework)/Headers/Generated.h")
  }

  func readLiveHeader(framework: String = "Foo") throws -> String {
    try String(contentsOf: liveHeaderURL(framework: framework), encoding: .utf8)
  }
}

private func sharedCacheInventoryData(
  producerVersion: String = PrivateHeaderKitBuildInfo.version,
  cacheUUID: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
  imagePaths: [String]
) throws -> Data {
  try JSONEncoder().encode(
    PrivateHeaderKitSharedCacheInventory(
      producerVersion: producerVersion,
      cacheUUID: cacheUUID,
      imagePaths: imagePaths
    )
  )
}
