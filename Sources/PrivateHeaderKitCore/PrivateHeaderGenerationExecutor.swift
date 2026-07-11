import CryptoKit
import Foundation

extension PrivateHeaderGeneration {
  package static func availableResumeSummary(
    source: Source,
    output: Output,
    options: Options = Options()
  ) async throws -> ResumeSummary? {
    let plan = makePlan(source: source, output: output, options: options)
    return try await GenerationExecutor.availableResumeSummary(for: plan)
  }

  package struct GenerationExecutor: Sendable {
    private struct DeliberateFault: Error, @unchecked Sendable {
      let underlying: any Error
    }

    package typealias RawDumpRunner =
      @Sendable (
        PrivateHeaderGeneration.RawDumping.Invocation
      ) async throws -> PrivateHeaderGeneration.RawDumping.Result
    package typealias ProgressReporter =
      @Sendable (
        PrivateHeaderGeneration.ProgressEvent
      ) -> Void
    package typealias PublicationFaultInjector =
      @Sendable (
        PrivateHeaderGeneration.PublicationFaultPoint
      ) throws -> Void

    package struct Configuration: Sendable {
      package let plan: Plan
      package let progressReporter: ProgressReporter?

      package init(plan: Plan, progressReporter: ProgressReporter? = nil) {
        self.plan = plan
        self.progressReporter = progressReporter
      }
    }

    private let rawDumpRunner: RawDumpRunner
    private let runIDGenerator: @Sendable () -> String
    private let generationIDGenerator: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date
    private let storeFaultInjector: GenerationStore.FaultInjector
    private let publicationFaultInjector: PublicationFaultInjector

    package init(
      rawDumpRunner: @escaping RawDumpRunner,
      runIDGenerator: @escaping @Sendable () -> String = {
        "run-\(UUID().uuidString.lowercased())"
      },
      generationIDGenerator: @escaping @Sendable () -> String = {
        "generation-\(UUID().uuidString.lowercased())"
      },
      dateProvider: @escaping @Sendable () -> Date = { Date() },
      storeFaultInjector: @escaping GenerationStore.FaultInjector = { _ in },
      publicationFaultInjector: @escaping PublicationFaultInjector = { _ in }
    ) {
      self.rawDumpRunner = rawDumpRunner
      self.runIDGenerator = runIDGenerator
      self.generationIDGenerator = generationIDGenerator
      self.dateProvider = dateProvider
      self.storeFaultInjector = storeFaultInjector
      self.publicationFaultInjector = publicationFaultInjector
    }

    package func run(_ configuration: Configuration) async throws -> Result {
      let plan = configuration.plan
      let options = plan.options
      guard let systemRoot = options.systemRoot else {
        throw GenerationError.missingExecutionConfiguration("systemRoot")
      }
      guard let helperURLs = options.helperURLs else {
        throw GenerationError.missingExecutionConfiguration("helperURLs")
      }
      guard let executionMode = options.executionMode else {
        throw GenerationError.missingExecutionConfiguration("executionMode")
      }

      let catalog = try TargetDiscovery.discover(
        in: systemRoot,
        includeNestedChildren: options.includeNestedChildren
      )
      let selectedTargets = try Self.selectedExecutionTargets(
        request: options.targetRequest,
        catalog: catalog
      )
      guard !selectedTargets.isEmpty else {
        throw GenerationError.noDiscoveredTargets(systemRoot: systemRoot.path)
      }

      let publisher = try ArtifactPublisher(
        artifactBaseDirectory: plan.output.baseDirectory,
        sourceLabel: plan.source.storageIdentifier
      )
      try publisher.prepareForLease()
      return try await GenerationLease.withExclusiveLease(at: publisher.lockURL) {
        let stateDirectory = Self.canonicalStateDirectory(
          outputBase: publisher.artifactBaseDirectory,
          sourceLabel: plan.source.storageIdentifier
        )
        let databaseURL = stateDirectory.appendingPathComponent(
          "generation.sqlite",
          isDirectory: false
        )
        let hadDatabase = try Self.regularFileExists(databaseURL)
        if try Self.legacyStateExists(in: stateDirectory),
          !hadDatabase,
          !options.resumeBehavior.isFresh
        {
          throw GenerationError.legacyStateRequiresFresh(path: stateDirectory.path)
        }
        let injectedStoreFault = storeFaultInjector
        let store = try GenerationStore(
          databaseURL: databaseURL,
          toolVersion: options.toolVersion,
          faultInjector: { point in
            do {
              try injectedStoreFault(point)
            } catch {
              throw DeliberateFault(underlying: error)
            }
          }
        )
        return try await runWithLease(
          plan: plan,
          stateDirectory: stateDirectory,
          databaseURL: databaseURL,
          selectedTargets: selectedTargets,
          store: store,
          publisher: publisher,
          helperURLs: helperURLs,
          executionMode: executionMode,
          progressReporter: configuration.progressReporter
        )
      }
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate struct TargetExecution {
    let result: PrivateHeaderGeneration.TargetAttemptResult
    let completedFiles: [PrivateHeaderGeneration.ArtifactPath: URL]
  }

  fileprivate struct StagedArtifacts {
    let files: [PrivateHeaderGeneration.ArtifactPath: URL]
  }

  fileprivate func cancellationRequested() -> Bool {
    Task.isCancelled
  }

  fileprivate func latchCancellation(
    _ wasCancelled: Bool,
    runID: PrivateHeaderGeneration.RunID,
    store: GenerationStore
  ) async throws -> Bool {
    guard !wasCancelled, cancellationRequested() else { return wasCancelled }
    try await store.requestInterruption(runID, at: dateProvider())
    return true
  }

  fileprivate func runWithLease(
    plan: PrivateHeaderGeneration.Plan,
    stateDirectory: URL,
    databaseURL: URL,
    selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
    store: GenerationStore,
    publisher: ArtifactPublisher,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    progressReporter: ProgressReporter?
  ) async throws -> PrivateHeaderGeneration.Result {
    try await Self.recover(store: store, publisher: publisher, at: dateProvider())
    try publisher.cleanupStaging()
    try Self.cleanupStateStaging(in: stateDirectory)
    let publication = try publisher.inspect()

    if publication.stablePathState == .legacyDirectory,
      !plan.options.resumeBehavior.isFresh
    {
      throw PrivateHeaderGeneration.GenerationError.legacyArtifactsRequireFresh(
        path: publisher.stableURL.path
      )
    }

    let targetIDs = selectedTargets.map(\.candidate.identifier)
    let fingerprint = Self.planFingerprint(
      plan,
      canonicalOutputBase: publisher.artifactBaseDirectory,
      executionMode: executionMode
    )
    let resumeSummary: PrivateHeaderGeneration.ResumeSummary?
    if plan.options.resumeBehavior.isFresh {
      resumeSummary = nil
    } else {
      resumeSummary = try await store.resumeSummary(
        planFingerprint: fingerprint,
        selectedTargetIDs: targetIDs,
        currentArtifactsByTarget: publication.currentMarker?.artifactsByTarget ?? [:],
        at: dateProvider()
      )
      if let resumeSummary,
        resumeSummary.isUnfinished,
        !plan.options.resumeBehavior.resumeRequested
      {
        throw PrivateHeaderGeneration.GenerationError.resumeRequired(resumeSummary)
      }
    }

    let targetIDsToRun: Set<String>
    if let resumeSummary {
      targetIDsToRun = Set(resumeSummary.targets.filter(\.shouldRun).map(\.targetID))
    } else {
      targetIDsToRun = Set(targetIDs)
    }

    let runID = try PrivateHeaderGeneration.RunID(runIDGenerator())
    let generationID = try PrivateHeaderGeneration.GenerationID(generationIDGenerator())
    let runPlan = PrivateHeaderGeneration.RunPlan(
      sourceIdentity: plan.source.storageIdentifier,
      fingerprint: fingerprint,
      targetIDs: targetIDs,
      toolVersion: plan.options.toolVersion
    )
    _ = try await store.beginRun(id: runID, plan: runPlan, at: dateProvider())
    progressReporter?(.runStarted(runID: runID, totalTargetCount: targetIDsToRun.count))

    do {
      for target in selectedTargets where !targetIDsToRun.contains(target.candidate.identifier) {
        try await store.markSkipped(
          targetID: target.candidate.identifier,
          in: runID,
          at: dateProvider()
        )
      }

      if targetIDsToRun.isEmpty {
        let wasCancelled = cancellationRequested()
        if wasCancelled {
          try await store.requestInterruption(runID, at: dateProvider())
        }
        let snapshot = try await store.finishRunWithoutPublication(
          runID,
          at: dateProvider(),
          shouldInterrupt: { cancellationRequested() }
        )
        let summary = PrivateHeaderGeneration.RunSummary(
          runID: runID,
          status: snapshot.status,
          targetCounts: snapshot.counts,
          artifactDirectory: publisher.stableURL,
          stateDatabaseURL: databaseURL
        )
        progressReporter?(.runFinished(summary))
        if snapshot.status == .interrupted {
          throw PrivateHeaderGeneration.GenerationError.runInterrupted(
            .init(summary: summary)
          )
        }
        return PrivateHeaderGeneration.Result(
          plan: plan,
          artifactDirectory: publisher.stableURL,
          generatedTargets: [],
          runID: runID,
          stateDatabaseURL: databaseURL,
          targetCounts: snapshot.counts
        )
      }

      var draft = try publisher.beginDraft(
        generationID: generationID,
        allowLegacyMigration: plan.options.resumeBehavior.isFresh
      )
      let runStagingDirectory =
        stateDirectory
        .appendingPathComponent("staging", isDirectory: true)
        .appendingPathComponent(runID.rawValue, isDirectory: true)
      try Self.ensureEmptyDirectory(runStagingDirectory)

      var generatedTargetIDs: [String] = []
      var warnings: [PrivateHeaderGeneration.GenerationWarning] = []
      var wasCancelled = false
      var executedIndex = 0

      for target in selectedTargets where targetIDsToRun.contains(target.candidate.identifier) {
        executedIndex += 1
        let targetID = target.candidate.identifier
        try await store.beginTargetAttempt(
          targetID: targetID,
          displayName: target.candidate.displayName,
          kind: target.candidate.kind.rawValue,
          in: runID,
          at: dateProvider()
        )
        progressReporter?(
          .targetStarted(
            index: executedIndex,
            total: targetIDsToRun.count,
            displayName: target.candidate.displayName
          ))

        if cancellationRequested() {
          let result = Self.interruptedResult(target: target, at: dateProvider())
          try await store.recordTargetAttempt(result, in: runID)
          try await store.requestInterruption(runID, at: dateProvider())
          progressReporter?(
            .targetFinished(
              index: executedIndex,
              total: targetIDsToRun.count,
              displayName: target.candidate.displayName,
              status: .interrupted
            ))
          wasCancelled = true
          break
        }

        let targetStagingDirectory = runStagingDirectory.appendingPathComponent(
          Self.safeTargetDirectoryName(targetID),
          isDirectory: true
        )
        try Self.ensureEmptyDirectory(targetStagingDirectory)
        let execution = try await executeTarget(
          target,
          plan: plan,
          helperURLs: helperURLs,
          executionMode: executionMode,
          stagingDirectory: targetStagingDirectory,
          publisher: publisher
        )

        if execution.result.status == .completed {
          draft = try publisher.applyCompletedTarget(
            targetID: targetID,
            files: execution.completedFiles,
            to: draft
          )
          generatedTargetIDs.append(targetID)
        }

        try await store.recordTargetAttempt(execution.result, in: runID)
        progressReporter?(
          .targetFinished(
            index: executedIndex,
            total: targetIDsToRun.count,
            displayName: target.candidate.displayName,
            status: execution.result.status
          ))
        if cancellationRequested(), execution.result.status != .interrupted {
          try await store.requestInterruption(runID, at: dateProvider())
          wasCancelled = true
        }
        if execution.result.status == .interrupted {
          try await store.requestInterruption(runID, at: dateProvider())
          wasCancelled = true
        }
        if wasCancelled { break }
      }

      if cancellationRequested() {
        wasCancelled = true
      }
      if wasCancelled {
        try await store.requestInterruption(runID, at: dateProvider())
      }

      let finalSnapshot: PrivateHeaderGeneration.RunSnapshot
      if generatedTargetIDs.isEmpty {
        finalSnapshot = try await store.finishRunWithoutPublication(
          runID,
          at: dateProvider(),
          shouldInterrupt: { cancellationRequested() }
        )
        wasCancelled = finalSnapshot.status == .interrupted
        do {
          try publisher.discardDraft(draft)
        } catch {
          warnings.append(
            await surfacePostCommitWarning(
              runID: runID,
              kind: "cleanup-warning",
              relativePath:
                ".privateheaderkit/\(plan.source.storageIdentifier)/staging/\(generationID.rawValue).draft",
              error: error,
              store: store,
              progressReporter: progressReporter
            ))
        }
      } else {
        let prepared = try publisher.prepareGeneration(draft, planFingerprint: fingerprint)
        let previousGenerationID = publication.currentGenerationID
        _ = try await store.preparePublication(
          generationID: generationID,
          runID: runID,
          previousGenerationID: previousGenerationID,
          planFingerprint: fingerprint,
          artifactChecksum: prepared.marker.artifactChecksum,
          at: dateProvider()
        )
        try injectPublicationFault(.afterPrepared)
        wasCancelled = try await latchCancellation(
          wasCancelled,
          runID: runID,
          store: store
        )
        try publisher.movePreparedGeneration(prepared)
        try injectPublicationFault(.afterGenerationMove)
        wasCancelled = try await latchCancellation(
          wasCancelled,
          runID: runID,
          store: store
        )
        try publisher.switchCurrent(to: generationID)
        try injectPublicationFault(.afterCurrentPointerSwitch)
        wasCancelled = try await latchCancellation(
          wasCancelled,
          runID: runID,
          store: store
        )
        try publisher.ensureStablePointer()
        try injectPublicationFault(.afterStablePointerSwitch)
        wasCancelled = try await latchCancellation(
          wasCancelled,
          runID: runID,
          store: store
        )
        try await store.markPointerPublished(generationID)
        try injectPublicationFault(.beforeCommitted)
        wasCancelled = try await latchCancellation(
          wasCancelled,
          runID: runID,
          store: store
        )
        finalSnapshot = try await store.completePublication(
          generationID,
          at: dateProvider(),
          shouldInterrupt: { cancellationRequested() }
        )
        wasCancelled = finalSnapshot.status == .interrupted
        var protected: Set<PrivateHeaderGeneration.GenerationID> = [generationID]
        if let previousGenerationID { protected.insert(previousGenerationID) }
        do {
          try publisher.retainGenerations(
            protected: protected,
            maximumCount: max(3, protected.count)
          )
        } catch {
          warnings.append(
            await surfacePostCommitWarning(
              runID: runID,
              kind: "retention-warning",
              relativePath: ".privateheaderkit/\(plan.source.storageIdentifier)/generations",
              error: error,
              store: store,
              progressReporter: progressReporter
            ))
        }
        try publisher.validateCommittedCurrent(generationID)
      }

      do {
        try FileManager.default.removeItem(at: runStagingDirectory)
      } catch {
        warnings.append(
          await surfacePostCommitWarning(
            runID: runID,
            kind: "cleanup-warning",
            relativePath: "staging/\(runID.rawValue)",
            error: error,
            store: store,
            progressReporter: progressReporter
          ))
      }
      let summary = PrivateHeaderGeneration.RunSummary(
        runID: runID,
        status: finalSnapshot.status,
        targetCounts: finalSnapshot.counts,
        artifactDirectory: publisher.stableURL,
        stateDatabaseURL: databaseURL,
        warnings: warnings
      )
      progressReporter?(.runFinished(summary))
      if wasCancelled {
        throw PrivateHeaderGeneration.GenerationError.runInterrupted(
          .init(summary: summary)
        )
      }

      let failedTargetIDs = finalSnapshot.targets
        .filter { !$0.status.isSuccessfulOrSkipped }
        .map(\.targetID)
      if !failedTargetIDs.isEmpty {
        throw PrivateHeaderGeneration.GenerationError.runFailed(
          .init(summary: summary, failedTargetIDs: failedTargetIDs)
        )
      }

      return PrivateHeaderGeneration.Result(
        plan: plan,
        artifactDirectory: publisher.stableURL,
        generatedTargets: generatedTargetIDs.map(
          PrivateHeaderGeneration.Target.generated(identifier:)),
        runID: runID,
        stateDatabaseURL: databaseURL,
        targetCounts: finalSnapshot.counts,
        warnings: warnings
      )
    } catch let fault as DeliberateFault {
      throw fault.underlying
    } catch let error as PrivateHeaderGeneration.GenerationError {
      throw error
    } catch {
      try await convergeInfrastructureFailure(
        error,
        runID: runID,
        generationID: generationID,
        databaseURL: databaseURL,
        stateDirectory: stateDirectory,
        store: store,
        publisher: publisher,
        progressReporter: progressReporter
      )
    }
  }

  fileprivate func injectPublicationFault(
    _ point: PrivateHeaderGeneration.PublicationFaultPoint
  ) throws {
    do {
      try publicationFaultInjector(point)
    } catch {
      throw DeliberateFault(underlying: error)
    }
  }

  fileprivate func convergeInfrastructureFailure(
    _ underlyingError: any Error,
    runID: PrivateHeaderGeneration.RunID,
    generationID: PrivateHeaderGeneration.GenerationID,
    databaseURL: URL,
    stateDirectory: URL,
    store: GenerationStore,
    publisher: ArtifactPublisher,
    progressReporter: ProgressReporter?
  ) async throws -> Never {
    let interruptionRequested = cancellationRequested()
    if interruptionRequested {
      try await store.requestInterruption(runID, at: dateProvider())
    }
    if try await store.publicationIntent(generationID: generationID) == nil {
      if interruptionRequested {
        _ = try await store.finishRunWithoutPublication(
          runID,
          at: dateProvider(),
          shouldInterrupt: { true }
        )
      } else {
        _ = try await store.failRun(
          runID,
          message: String(describing: underlyingError),
          at: dateProvider()
        )
      }
    } else {
      try await Self.recover(store: store, publisher: publisher, at: dateProvider())
    }
    var warnings: [PrivateHeaderGeneration.GenerationWarning] = []
    do {
      try publisher.cleanupStaging()
    } catch {
      warnings.append(
        await surfacePostCommitWarning(
          runID: runID,
          kind: "cleanup-warning",
          relativePath: ".privateheaderkit/\(publisher.sourceLabel)/staging",
          error: error,
          store: store,
          progressReporter: progressReporter
        ))
    }
    do {
      try Self.cleanupStateStaging(in: stateDirectory)
    } catch {
      warnings.append(
        await surfacePostCommitWarning(
          runID: runID,
          kind: "cleanup-warning",
          relativePath: "staging",
          error: error,
          store: store,
          progressReporter: progressReporter
        ))
    }
    let snapshot = try await store.runSnapshot(runID)
    guard snapshot.status != .running else {
      throw PrivateHeaderGeneration.StateError.corruptPublication(
        "in-process failure recovery left run \(runID.rawValue) running"
      )
    }
    let summary = PrivateHeaderGeneration.RunSummary(
      runID: runID,
      status: snapshot.status,
      targetCounts: snapshot.counts,
      artifactDirectory: publisher.stableURL,
      stateDatabaseURL: databaseURL,
      warnings: warnings
    )
    progressReporter?(.runFinished(summary))
    if interruptionRequested {
      throw PrivateHeaderGeneration.GenerationError.runInterrupted(
        .init(summary: summary)
      )
    }
    throw PrivateHeaderGeneration.GenerationError.infrastructureFailed(
      .init(summary: summary, message: String(describing: underlyingError))
    )
  }

  fileprivate func surfacePostCommitWarning(
    runID: PrivateHeaderGeneration.RunID,
    kind: String,
    relativePath: String,
    error: any Error,
    store: GenerationStore,
    progressReporter: ProgressReporter?
  ) async -> PrivateHeaderGeneration.GenerationWarning {
    let primaryMessage = String(describing: error)
    let message: String
    do {
      try await store.recordRunLog(
        runID: runID,
        kind: kind,
        relativePath: relativePath,
        message: primaryMessage
      )
      message = primaryMessage
    } catch {
      message = "\(primaryMessage); additionally failed to persist warning: \(error)"
    }
    let warning = PrivateHeaderGeneration.GenerationWarning(
      kind: kind,
      relativePath: relativePath,
      message: message
    )
    progressReporter?(.warning(warning))
    return warning
  }

  fileprivate func executeTarget(
    _ target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    plan: PrivateHeaderGeneration.Plan,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    stagingDirectory: URL,
    publisher: ArtifactPublisher
  ) async throws -> TargetExecution {
    let now = dateProvider()
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      PrivateHeaderGeneration.RawDumping.Request(
        helperURLs: helperURLs,
        executionMode: executionMode,
        inputPath: Self.inputPath(for: target, executionMode: executionMode),
        stagingOutputDirectory: stagingDirectory,
        options: plan.options.rawDumpingOptions
      )
    )

    let rawResult: PrivateHeaderGeneration.RawDumping.Result
    do {
      rawResult = try await rawDumpRunner(invocation)
    } catch is CancellationError {
      return TargetExecution(
        result: Self.interruptedResult(target: target, at: dateProvider()),
        completedFiles: [:]
      )
    } catch {
      return Self.failedExecution(
        target: target,
        status: cancellationRequested() ? .interrupted : .failed,
        summary: String(describing: error),
        at: now
      )
    }

    if cancellationRequested() {
      return TargetExecution(
        result: Self.interruptedResult(target: target, at: dateProvider()),
        completedFiles: [:]
      )
    }
    let artifactRoot = try Self.artifactRoot(for: target, layout: plan.options.layout)
    let staged = try Self.collectStagedArtifacts(
      for: target,
      in: stagingDirectory,
      runtimeRoot: plan.options.systemRoot?.path ?? "",
      artifactRoot: artifactRoot
    )
    try publisher.validateRawStaging(
      root: stagingDirectory,
      expectedSourceFiles: Set(staged.files.values)
    )
    guard !staged.files.isEmpty else {
      return Self.failedExecution(
        target: target,
        status: .failed,
        summary: rawResult.succeeded
          ? "raw dump produced no header artifacts"
          : rawResult.failureSummary
            ?? "raw dump exited with status \(rawResult.terminationStatus)",
        at: dateProvider()
      )
    }
    if rawResult.succeeded {
      return TargetExecution(
        result: PrivateHeaderGeneration.TargetAttemptResult(
          targetID: target.candidate.identifier,
          displayName: target.candidate.displayName,
          kind: target.candidate.kind.rawValue,
          status: .completed,
          artifacts: staged.files.keys.sorted { $0.rawValue < $1.rawValue },
          completedAt: dateProvider()
        ),
        completedFiles: staged.files
      )
    }
    return Self.failedExecution(
      target: target,
      status: .partial,
      summary: rawResult.failureSummary
        ?? "raw dump exited with status \(rawResult.terminationStatus)",
      artifacts: staged.files.keys.sorted { $0.rawValue < $1.rawValue },
      at: dateProvider()
    )
  }

  fileprivate static func failedExecution(
    target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    status: PrivateHeaderGeneration.RunTargetStatus,
    summary: String,
    artifacts: [PrivateHeaderGeneration.ArtifactPath] = [],
    at date: Date
  ) -> TargetExecution {
    TargetExecution(
      result: PrivateHeaderGeneration.TargetAttemptResult(
        targetID: target.candidate.identifier,
        displayName: target.candidate.displayName,
        kind: target.candidate.kind.rawValue,
        status: status,
        artifacts: artifacts,
        failureSummary: summary,
        completedAt: date
      ),
      completedFiles: [:]
    )
  }

  fileprivate static func interruptedResult(
    target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    at date: Date
  ) -> PrivateHeaderGeneration.TargetAttemptResult {
    PrivateHeaderGeneration.TargetAttemptResult(
      targetID: target.candidate.identifier,
      displayName: target.candidate.displayName,
      kind: target.candidate.kind.rawValue,
      status: .interrupted,
      failureSummary: "cancelled",
      completedAt: date
    )
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate static func recover(
    store: GenerationStore,
    publisher: ArtifactPublisher,
    at date: Date
  ) async throws {
    for _ in 0..<4 {
      let snapshot = try publisher.inspect()
      let action = try await store.recover(using: snapshot, at: date)
      switch action {
      case .completeStablePointer:
        try publisher.ensureStablePointer()
        continue
      case .discardGeneration(let generationID):
        try publisher.discardGeneration(generationID)
        continue
      case .none, .recognized, .rolledForward:
        return
      }
    }
    throw PrivateHeaderGeneration.StateError.corruptPublication("recovery did not converge")
  }

  fileprivate static func availableResumeSummary(
    for plan: PrivateHeaderGeneration.Plan
  ) async throws -> PrivateHeaderGeneration.ResumeSummary? {
    guard let systemRoot = plan.options.systemRoot else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("systemRoot")
    }
    guard let executionMode = plan.options.executionMode else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
    }
    let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
      in: systemRoot,
      includeNestedChildren: plan.options.includeNestedChildren
    )
    let selectedTargets = try selectedExecutionTargets(
      request: plan.options.targetRequest,
      catalog: catalog
    )
    let publisher = try ArtifactPublisher(
      artifactBaseDirectory: plan.output.baseDirectory,
      sourceLabel: plan.source.storageIdentifier
    )
    try publisher.prepareForLease()
    return try await GenerationLease.withExclusiveLease(at: publisher.lockURL) {
      let stateDirectory = canonicalStateDirectory(
        outputBase: publisher.artifactBaseDirectory,
        sourceLabel: plan.source.storageIdentifier
      )
      let databaseURL = stateDirectory.appendingPathComponent(
        "generation.sqlite",
        isDirectory: false
      )
      let hadDatabase = try regularFileExists(databaseURL)
      if try legacyStateExists(in: stateDirectory),
        !hadDatabase,
        !plan.options.resumeBehavior.isFresh
      {
        throw PrivateHeaderGeneration.GenerationError.legacyStateRequiresFresh(
          path: stateDirectory.path
        )
      }
      let store = try GenerationStore(
        databaseURL: databaseURL,
        toolVersion: plan.options.toolVersion
      )
      try await recover(store: store, publisher: publisher, at: Date())
      try publisher.cleanupStaging()
      try cleanupStateStaging(in: stateDirectory)
      let publication = try publisher.inspect()
      if publication.stablePathState == .legacyDirectory,
        !plan.options.resumeBehavior.isFresh
      {
        throw PrivateHeaderGeneration.GenerationError.legacyArtifactsRequireFresh(
          path: publisher.stableURL.path
        )
      }
      guard !plan.options.resumeBehavior.isFresh else { return nil }
      let summary = try await store.resumeSummary(
        planFingerprint: planFingerprint(
          plan,
          canonicalOutputBase: publisher.artifactBaseDirectory,
          executionMode: executionMode
        ),
        selectedTargetIDs: selectedTargets.map(\.candidate.identifier),
        currentArtifactsByTarget: publication.currentMarker?.artifactsByTarget ?? [:],
        at: Date()
      )
      return summary?.isUnfinished == true ? summary : nil
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate static func selectedExecutionTargets(
    request: PrivateHeaderGeneration.TargetRequest,
    catalog: PrivateHeaderGeneration.TargetDiscovery.Catalog
  ) throws -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
    switch request {
    case .frameworks:
      return deduplicated(
        catalog.targets.flatMap {
          target -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] in
          guard target.candidate.kind == .framework || target.candidate.kind == .privateFramework
          else {
            return []
          }
          return [target] + target.childTargets
        }
      )
    case .system:
      return deduplicated(
        catalog.targets.flatMap {
          target -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] in
          guard target.candidate.kind != .usrLibDylib else { return [] }
          return [target] + target.childTargets
        }
      )
    case .allAvailable:
      return deduplicated(catalog.allTargetsIncludingNestedChildren)
    case .identifiers(let targetIDs):
      let requested = deduplicatedTargetIDs(targetIDs)
      let all = catalog.allTargetsIncludingNestedChildren
      let selected = requested.compactMap { id in all.first { $0.candidate.identifier == id } }
      if selected.count != requested.count {
        let found = Set(selected.map(\.candidate.identifier))
        throw PrivateHeaderGeneration.GenerationError.unknownSelectedTargets(
          requested.filter { !found.contains($0) }.sorted()
        )
      }
      return deduplicated(selected)
    case .query(let query):
      let targetQuery = try PrivateHeaderGeneration.TargetQuery(commaSeparated: query)
      switch catalog.resolver.resolve(targetQuery) {
      case .selected(.allAvailable):
        return deduplicated(catalog.allTargetsIncludingNestedChildren)
      case .selected(.targets(let candidates)):
        return deduplicated(
          candidates.flatMap { candidate in
            expandTarget(identifier: candidate.identifier, catalog: catalog)
          })
      case .needsDisambiguation, .failed, .unresolved:
        throw PrivateHeaderGeneration.GenerationError.unresolvedTargetQuery(query)
      }
    }
  }

  fileprivate static func expandTarget(
    identifier: String,
    catalog: PrivateHeaderGeneration.TargetDiscovery.Catalog
  ) -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
    for target in catalog.targets where target.candidate.identifier == identifier {
      return [target] + target.childTargets
    }
    return catalog.allTargetsIncludingNestedChildren.filter {
      $0.candidate.identifier == identifier
    }
  }

  fileprivate static func deduplicated(
    _ targets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget]
  ) -> [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget] {
    var seen: Set<String> = []
    return targets.filter { seen.insert($0.candidate.identifier).inserted }
  }

  fileprivate static func deduplicatedTargetIDs(_ targetIDs: [String]) -> [String] {
    var seen: Set<String> = []
    return targetIDs.filter { seen.insert($0).inserted }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate static func collectStagedArtifacts(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    in targetStagingDirectory: URL,
    runtimeRoot: String,
    artifactRoot: PrivateHeaderGeneration.ArtifactPath
  ) throws -> StagedArtifacts {
    let candidates = stagedSourceDirectoryCandidates(
      for: target,
      in: targetStagingDirectory,
      runtimeRoot: runtimeRoot
    )
    for candidate in candidates where try directoryExists(candidate) {
      let files = try artifactFiles(under: candidate, artifactRoot: artifactRoot)
      if !files.isEmpty { return StagedArtifacts(files: files) }
    }
    return StagedArtifacts(files: [:])
  }

  fileprivate static func artifactFiles(
    under sourceDirectory: URL,
    artifactRoot: PrivateHeaderGeneration.ArtifactPath
  ) throws -> [PrivateHeaderGeneration.ArtifactPath: URL] {
    var enumerationFailure: (URL, any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceDirectory,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { url, error in
          enumerationFailure = (url, error)
          return false
        }
      )
    else {
      throw ArtifactPublisher.PublisherError.unexpectedItem(
        path: sourceDirectory.path,
        description: "could not enumerate raw staging"
      )
    }
    let sourcePath = sourceDirectory.standardizedFileURL.path
    var result: [PrivateHeaderGeneration.ArtifactPath: URL] = [:]
    for case let url as URL in enumerator {
      let kind = try publisherItemKind(at: url)
      if kind == .directory { continue }
      guard kind == .regular, url.pathExtension == "h" || url.pathExtension == "swiftinterface"
      else {
        continue
      }
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(sourcePath + "/") else {
        throw ArtifactPublisher.PublisherError.invalidManagedPath(path)
      }
      let relative = String(path.dropFirst(sourcePath.count + 1))
      let artifact = try PrivateHeaderGeneration.ArtifactPath(
        artifactRoot.rawValue + "/" + relative
      )
      guard result.updateValue(url, forKey: artifact) == nil else {
        throw ArtifactPublisher.PublisherError.artifactCollision(
          path: artifact.rawValue,
          owners: [targetIDForDiagnostic(sourceDirectory)]
        )
      }
    }
    if let (url, error) = enumerationFailure {
      throw ArtifactPublisher.PublisherError.unexpectedItem(
        path: url.path,
        description: "raw staging enumeration failed: \(error)"
      )
    }
    return result
  }

  fileprivate static func targetIDForDiagnostic(_ sourceDirectory: URL) -> String {
    sourceDirectory.lastPathComponent
  }

  fileprivate static func stagedSourceDirectoryCandidates(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    in targetStagingDirectory: URL,
    runtimeRoot: String
  ) -> [URL] {
    let runtimeInputPath = target.runtimeInputPath
    let trimmed = runtimeInputPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if runtimeInputPath.hasPrefix("/usr/lib/") {
      let name = URL(fileURLWithPath: runtimeInputPath).lastPathComponent
      return stageUsrLibRoots(stageDirectory: targetStagingDirectory, runtimeRoot: runtimeRoot)
        .map { $0.appendingPathComponent(name, isDirectory: true) }
    }
    let relative = String(runtimeInputPath.dropFirst("/System/Library/".count))
    var candidates = stageSystemLibraryRoots(
      stageDirectory: targetStagingDirectory,
      runtimeRoot: runtimeRoot
    ).map { appendRelativePath(relative, to: $0) }
    candidates.append(appendRelativePath(trimmed, to: targetStagingDirectory))
    return candidates
  }

  fileprivate static func artifactRoot(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    layout: PrivateHeaderGeneration.Layout
  ) throws -> PrivateHeaderGeneration.ArtifactPath {
    switch layout {
    case .headers:
      target.artifactRoot
    case .bundle:
      try bundleArtifactRoot(for: target.source)
    }
  }

  fileprivate static func bundleArtifactRoot(
    for source: PrivateHeaderGeneration.TargetDiscovery.SourceMetadata
  ) throws -> PrivateHeaderGeneration.ArtifactPath {
    switch source {
    case .framework(let framework):
      try PrivateHeaderGeneration.ArtifactPath(framework.systemLibraryRelativePath)
    case .systemLibraryBundle(let bundle):
      try PrivateHeaderGeneration.ArtifactPath(
        artifactRootForBundleLayout(systemLibraryRelativePath: bundle.relativePath)
      )
    case .usrLibDylib(let dylib):
      try PrivateHeaderGeneration.ArtifactPath("usr/lib/\(dylib.name)")
    }
  }

  fileprivate static func artifactRootForBundleLayout(systemLibraryRelativePath: String) -> String {
    let first = systemLibraryRelativePath.split(separator: "/", maxSplits: 1).first
    if first == "Frameworks" || first == "PrivateFrameworks" { return systemLibraryRelativePath }
    return "SystemLibrary/\(systemLibraryRelativePath)"
  }

  fileprivate static func inputPath(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
  ) -> String {
    switch executionMode {
    case .host: target.inputPath
    case .simulator: target.runtimeInputPath
    }
  }

  fileprivate static func stageSystemLibraryRoots(stageDirectory: URL, runtimeRoot: String) -> [URL]
  {
    var roots = [
      stageDirectory.appendingPathComponent("System/Library", isDirectory: true),
      stageDirectory.appendingPathComponent(
        "System/Cryptexes/OS/System/Library", isDirectory: true),
      stageDirectory.appendingPathComponent(
        "System/Volumes/Preboot/Cryptexes/OS/System/Library", isDirectory: true),
    ]
    if runtimeRoot.hasPrefix("/") {
      let base = appendRelativePath(String(runtimeRoot.dropFirst()), to: stageDirectory)
      roots.append(base.appendingPathComponent("System/Library", isDirectory: true))
      roots.append(
        base.appendingPathComponent("System/Cryptexes/OS/System/Library", isDirectory: true))
      roots.append(
        base.appendingPathComponent(
          "System/Volumes/Preboot/Cryptexes/OS/System/Library", isDirectory: true))
    }
    return uniquedByPath(roots)
  }

  fileprivate static func stageUsrLibRoots(stageDirectory: URL, runtimeRoot: String) -> [URL] {
    var roots = [stageDirectory.appendingPathComponent("usr/lib", isDirectory: true)]
    if runtimeRoot.hasPrefix("/") {
      roots.append(
        appendRelativePath(String(runtimeRoot.dropFirst()), to: stageDirectory)
          .appendingPathComponent("usr/lib", isDirectory: true)
      )
    }
    return uniquedByPath(roots)
  }

  fileprivate static func appendRelativePath(_ relativePath: String, to base: URL) -> URL {
    var url = base
    for component in relativePath.split(separator: "/") {
      url.appendPathComponent(String(component), isDirectory: true)
    }
    return url
  }

  fileprivate static func uniquedByPath(_ urls: [URL]) -> [URL] {
    var seen: Set<String> = []
    return urls.filter { seen.insert($0.path).inserted }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate static func planFingerprint(
    _ plan: PrivateHeaderGeneration.Plan,
    canonicalOutputBase: URL,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
  ) -> String {
    var components = [
      plan.source.storageIdentifier,
      canonicalOutputBase.path,
      plan.options.layout.rawValue,
      plan.options.systemRoot?.standardizedFileURL.path ?? "",
      plan.options.toolVersion,
      String(plan.options.includeNestedChildren),
      String(plan.options.rawDumpingOptions.skipExisting),
      String(plan.options.rawDumpingOptions.useSharedCache),
      String(plan.options.rawDumpingOptions.verbose),
      String(plan.options.rawDumpingOptions.preferRuntimeMetadata),
      plan.options.helperURLs?.host.standardizedFileURL.path ?? "",
      plan.options.helperURLs?.simulator.standardizedFileURL.path ?? "",
    ]
    switch executionMode {
    case .host:
      components.append("host")
    case .simulator(let deviceUDID, let runtimeRoot):
      components += ["simulator", deviceUDID, runtimeRoot]
    }
    for key in plan.options.rawDumpingOptions.helperEnvironment.keys.sorted() {
      components.append("env:\(key)=\(plan.options.rawDumpingOptions.helperEnvironment[key] ?? "")")
    }
    let digest = SHA256.hash(data: Data(components.joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  fileprivate static func safeTargetDirectoryName(_ targetID: String) -> String {
    var result = ""
    for byte in targetID.utf8 {
      let alphaNumeric =
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
      let punctuation = byte == 45 || byte == 46 || byte == 95
      if alphaNumeric || punctuation {
        result.append(Character(UnicodeScalar(byte)))
      } else {
        result += String(format: "%%%02X", byte)
      }
    }
    return result
  }

  fileprivate static func ensureEmptyDirectory(_ url: URL) throws {
    do {
      try ManagedFileSystem.ensureRealDirectory(url.deletingLastPathComponent())
      if let kind = try ManagedFileSystem.itemKind(at: url) {
        guard kind == .directory else {
          throw ManagedFileSystem.Failure.unexpectedKind(
            path: url.path,
            expected: "directory or missing",
            actual: kind
          )
        }
        try FileManager.default.removeItem(at: url)
      }
      try ManagedFileSystem.ensureRealDirectory(url)
    } catch let error as ManagedFileSystem.Failure {
      throw stateFileSystemError(error)
    }
  }

  fileprivate static func cleanupStateStaging(in stateDirectory: URL) throws {
    let stagingDirectory = stateDirectory.appendingPathComponent("staging", isDirectory: true)
    do {
      try ManagedFileSystem.ensureRealDirectory(stagingDirectory)
    } catch let error as ManagedFileSystem.Failure {
      throw stateFileSystemError(error)
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: stagingDirectory,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries {
      let kind: ManagedFileSystem.ItemKind?
      do {
        kind = try ManagedFileSystem.itemKind(at: entry)
      } catch let error as ManagedFileSystem.Failure {
        throw stateFileSystemError(error)
      }
      guard kind == .directory else {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "state staging entry is a symlink, missing, or non-directory: \(entry.path)"
        )
      }
      _ = try PrivateHeaderGeneration.RunID(entry.lastPathComponent)
      try FileManager.default.removeItem(at: entry)
    }
  }

  fileprivate static func directoryExists(_ url: URL) throws -> Bool {
    try publisherItemKind(at: url) == .directory
  }

  fileprivate static func pathExists(_ url: URL) throws -> Bool {
    do {
      return try ManagedFileSystem.itemKind(at: url) != nil
    } catch let error as ManagedFileSystem.Failure {
      throw stateFileSystemError(error)
    }
  }

  fileprivate static func regularFileExists(_ url: URL) throws -> Bool {
    do {
      return try ManagedFileSystem.requireRegularFileOrMissing(url)
    } catch let error as ManagedFileSystem.Failure {
      throw stateFileSystemError(error)
    }
  }

  fileprivate static func canonicalStateDirectory(outputBase: URL, sourceLabel: String) -> URL {
    outputBase
      .appendingPathComponent(".state", isDirectory: true)
      .appendingPathComponent(sourceLabel, isDirectory: true)
  }

  fileprivate static func legacyStateExists(in stateDirectory: URL) throws -> Bool {
    try pathExists(stateDirectory.appendingPathComponent("manifest.json"))
      || pathExists(stateDirectory.appendingPathComponent("runs", isDirectory: true))
  }

  fileprivate static func publisherItemKind(at url: URL) throws -> ManagedFileSystem.ItemKind? {
    do {
      return try ManagedFileSystem.itemKind(at: url)
    } catch let error as ManagedFileSystem.Failure {
      switch error {
      case .invalidPath(let path):
        throw ArtifactPublisher.PublisherError.invalidManagedPath(path)
      case .unexpectedKind(let path, let expected, let actual):
        throw ArtifactPublisher.PublisherError.unexpectedItem(
          path: path,
          description: "expected \(expected), found \(actual.rawValue)"
        )
      case .posix(let operation, let path, let code):
        throw ArtifactPublisher.PublisherError.posix(
          operation: operation,
          path: path,
          errno: code
        )
      }
    }
  }

  fileprivate static func stateFileSystemError(
    _ error: ManagedFileSystem.Failure
  ) -> PrivateHeaderGeneration.StateError {
    .corruptPublication(error.description)
  }
}

extension PrivateHeaderGeneration.ResumeBehavior {
  fileprivate var isFresh: Bool {
    if case .fresh = self { return true }
    return false
  }

  fileprivate var resumeRequested: Bool {
    switch self {
    case .resume: true
    case .fresh: false
    case .requireExplicitResume(let requested): requested
    }
  }
}
