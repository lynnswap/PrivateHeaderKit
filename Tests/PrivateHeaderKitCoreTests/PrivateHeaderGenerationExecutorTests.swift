import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationExecutorTests {
  private enum InjectedFault: Error {
    case stop
    case rawFailure
  }

  @Test func successfulRunPublishesImmutableGenerationAndCommitsStore() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    let runner = RecordingRunner(contents: "first")
    let executor = fixture.executor(
      runner: runner, runID: "run-001", generationID: "generation-001")

    let result = try await executor.run(.init(plan: try fixture.plan(.query("Foo"))))

    #expect(await runner.invocationCount == 1)
    #expect(result.generatedTargets.map(\.identifier) == ["framework:Foo.framework"])
    #expect(result.targetCounts.completed == 1)
    #expect(result.warnings.isEmpty)
    #expect(try fixture.readStableHeader() == "first")
    let publisher = try fixture.publisher()
    let publication = try publisher.inspect()
    #expect(publication.currentGenerationID == .init(rawValue: "generation-001"))
    let store = try GenerationStore(databaseURL: result.stateDatabaseURL, toolVersion: "test")
    #expect(try await store.runSnapshot(result.runID).status == .completed)
    #expect(
      try await store.targetSnapshot(targetID: "framework:Foo.framework")?.lastSuccessfulRunID
        == result.runID)
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
    ).run(.init(plan: plan))
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(.init(plan: plan))

    #expect(await secondRunner.invocationCount == 0)
    #expect(result.generatedTargets.isEmpty)
    #expect(result.targetCounts.skipped == 1)
    #expect(try fixture.readStableHeader() == "first")
  }

  @Test func failedAndPartialAttemptsPreserveLastSuccessfulGeneration() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.cleanup() }
    try fixture.createFramework("Foo.framework")
    _ = try await fixture.executor(
      runner: RecordingRunner(contents: "old"),
      runID: "run-001",
      generationID: "generation-001"
    ).run(.init(plan: try fixture.plan(.query("Foo"))))
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
      ).run(.init(plan: partialPlan))
      Issue.record("partial run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runFailed(failure) {
      #expect(failure.summary.runID == .init(rawValue: "run-002"))
      #expect(failure.summary.status == .partial)
      #expect(failure.summary.targetCounts.partial == 1)
      #expect(failure.summary.artifactDirectory == fixture.stableURL)
      #expect(failure.summary.stateDatabaseURL == fixture.databaseURL)
      #expect(failure.failedTargetIDs == ["framework:Foo.framework"])
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == oldCurrent)
    #expect(try fixture.readStableHeader() == "old")
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
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
      ).run(.init(plan: try fixture.plan(.query("Foo"))))
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.stableURL.path))
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
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
        .init(
          plan: plan,
          progressReporter: { event in
            progress.record(event)
          }))
      Issue.record("interrupted run unexpectedly returned success")
    } catch let PrivateHeaderGeneration.GenerationError.runInterrupted(interruption) {
      #expect(interruption.summary.status == .interrupted)
      #expect(interruption.summary.targetCounts.completed == 1)
      #expect(interruption.summary.targetCounts.interrupted == 1)
    }

    #expect(await runner.invocationCount == 2)
    #expect(try fixture.readStableHeader(framework: "Foo") == "generated")
    #expect(!FileManager.default.fileExists(atPath: fixture.stableHeaderURL(framework: "Bar").path))
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
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
    #expect(summary.artifactDirectory == fixture.stableURL)
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
      ).run(.init(plan: plan))
    }
    let interruption = try #require(capturedInterruption)
    #expect(interruption.summary.status == .interrupted)
    #expect(interruption.summary.targetCounts.completed == 1)
    #expect(interruption.summary.artifactDirectory == fixture.stableURL)

    #expect(await runner.invocationCount == 1)
    #expect(try fixture.readStableHeader() == "generated")
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
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
      ).run(.init(plan: plan))
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
      ).run(.init(plan: plan))
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
      ).run(.init(plan: plan))
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
    ).run(.init(plan: plan))
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
      ).run(.init(plan: plan))
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
      _ = try await first.run(.init(plan: plan))
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.stableURL.path))
    let secondRunner = RecordingRunner(contents: "should-not-run")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(.init(plan: plan))

    #expect(await secondRunner.invocationCount == 0)
    #expect(try fixture.readStableHeader() == "recoverable")
    let store = try GenerationStore(databaseURL: result.stateDatabaseURL, toolVersion: "test")
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
      ).run(.init(plan: plan))
    }
    let secondRunner = RecordingRunner(contents: "second-attempt")

    _ = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(.init(plan: plan))

    let shouldRerun = faultPoint == .afterPrepared || faultPoint == .afterGenerationMove
    #expect(await secondRunner.invocationCount == (shouldRerun ? 1 : 0))
    let expectedGeneration = PrivateHeaderGeneration.GenerationID(
      rawValue: shouldRerun ? "generation-002" : "generation-001"
    )
    let publication = try fixture.publisher().inspect()
    #expect(publication.currentGenerationID == expectedGeneration)
    #expect(try fixture.readStableHeader() == (shouldRerun ? "second-attempt" : "first-attempt"))
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
    let firstIntent = try #require(
      try await store.publicationIntent(generationID: .init(rawValue: "generation-001"))
    )
    #expect(firstIntent.state == (shouldRerun ? .aborted : .committed))
    #expect(
      try await store.runSnapshot(.init(rawValue: "run-001")).status
        == (shouldRerun ? .interrupted : .completed))
    if shouldRerun {
      #expect(!publication.validGenerationIDs.contains(.init(rawValue: "generation-001")))
      #expect(
        try await store.publicationIntent(generationID: .init(rawValue: "generation-002"))?.state
          == .committed)
    }
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
        ).run(.init(plan: plan))
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.databaseURL.path))
    }
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
    ).run(.init(plan: try fixture.plan(.query("Foo"))))

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
      ).run(.init(plan: try fixture.plan(.query("Foo"))))
      Issue.record("hidden raw payload unexpectedly succeeded")
    } catch let PrivateHeaderGeneration.GenerationError.infrastructureFailed(failure) {
      #expect(failure.summary.status == .failed)
      #expect(failure.summary.targetCounts.failed == 1)
      #expect(failure.message.contains("hidden staging payload"))
    }

    #expect(try fixture.publisher().inspect().currentGenerationID == nil)
    let store = try GenerationStore(databaseURL: fixture.databaseURL, toolVersion: "test")
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
    ).run(.init(plan: try fixture.plan(.query("Foo"))))
    let secondRunner = RecordingRunner(contents: "second")

    let result = try await fixture.executor(
      runner: secondRunner,
      runID: "run-002",
      generationID: "generation-002"
    ).run(.init(plan: try fixture.plan(.query("Foo"), outputBase: alias)))

    #expect(await secondRunner.invocationCount == 0)
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
    ).run(.init(plan: try fixture.plan(.query("Foo"), layout: .bundle)))

    let url = fixture.stableURL.appendingPathComponent(
      "Frameworks/Foo.framework/Headers/Generated.h")
    #expect(try String(contentsOf: url, encoding: .utf8) == "bundle")
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
      .init(
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
        }
      ))

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
  let cancelsForFramework: String?
  let afterRun: @Sendable () -> Void

  init(
    contents: String?,
    result: PrivateHeaderGeneration.RawDumping.Result = .init(terminationStatus: 0),
    thrownError: (any Error & Sendable)? = nil,
    writesHiddenPayload: Bool = false,
    cancelsForFramework: String? = nil,
    afterRun: @escaping @Sendable () -> Void = {}
  ) {
    self.contents = contents
    self.result = result
    self.thrownError = thrownError
    self.writesHiddenPayload = writesHiddenPayload
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
      try Data(contents.utf8).write(to: output.appendingPathComponent("Generated.h"))
      if writesHiddenPayload {
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

private struct ExecutorFixture {
  let root: URL
  let systemRoot: URL
  let outputBase: URL
  let helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs

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
    try FileManager.default.createDirectory(at: systemRoot, withIntermediateDirectories: true)
  }

  var sourceLabel: String { "macOS16.0(25A000)" }
  var stableURL: URL { outputBase.appendingPathComponent(sourceLabel, isDirectory: false) }
  var stateDirectory: URL {
    outputBase.appendingPathComponent(".state/\(sourceLabel)", isDirectory: true)
  }
  var databaseURL: URL { stateDirectory.appendingPathComponent("generation.sqlite") }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func createFramework(_ name: String) throws {
    try FileManager.default.createDirectory(
      at: systemRoot.appendingPathComponent("System/Library/Frameworks/\(name)", isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  func plan(
    _ targetRequest: PrivateHeaderGeneration.TargetRequest,
    layout: PrivateHeaderGeneration.Layout = .headers,
    resumeBehavior: PrivateHeaderGeneration.ResumeBehavior = .requireExplicitResume(
      resumeRequested: false),
    outputBase: URL? = nil
  ) throws -> PrivateHeaderGeneration.Plan {
    let source = try PrivateHeaderGeneration.Source(
      platform: .macOS,
      version: "16.0",
      build: "25A000"
    )
    return PrivateHeaderGeneration.makePlan(
      source: source,
      output: .init(baseDirectory: outputBase ?? self.outputBase),
      options: .init(
        layout: layout,
        targetRequest: targetRequest,
        systemRoot: systemRoot,
        helperURLs: helperURLs,
        executionMode: .host,
        resumeBehavior: resumeBehavior,
        toolVersion: "test"
      )
    )
  }

  func executor(
    runner: RecordingRunner,
    runID: String,
    generationID: String,
    storeFaultInjector: @escaping GenerationStore.FaultInjector = { _ in },
    publicationFaultInjector:
      @escaping PrivateHeaderGeneration.GenerationExecutor.PublicationFaultInjector = { _ in }
  ) -> PrivateHeaderGeneration.GenerationExecutor {
    .init(
      rawDumpRunner: { invocation in try await runner.run(invocation) },
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

  func readStableHeader(framework: String = "Foo") throws -> String {
    try String(contentsOf: stableHeaderURL(framework: framework), encoding: .utf8)
  }
}
