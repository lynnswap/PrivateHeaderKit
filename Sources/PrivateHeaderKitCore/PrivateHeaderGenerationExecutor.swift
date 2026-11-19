import CryptoKit
import Foundation
import PrivateHeaderKitHelperProtocol

extension PrivateHeaderGeneration {
  /// Runs a generation plan: dumps each selected target through a helper, publishes the
  /// result into the source's header directory, and records the run in the state database.
  package struct GenerationExecutor: Sendable {
    package static let maximumPresentedObjCMetadataWarningCount = 256

    package typealias RawDumpRunner =
      @Sendable (
        PrivateHeaderGeneration.RawDumping.Invocation
      ) async throws -> PrivateHeaderGeneration.RawDumping.Result
    package typealias SharedCacheInventoryRunner =
      @Sendable (
        PrivateHeaderGeneration.RawDumping.SharedCacheInventoryInvocation
      ) async throws -> Data
    package typealias ProgressReporter =
      @Sendable (
        PrivateHeaderGeneration.ProgressEvent
      ) -> Void

    package struct SharedCacheCohort: Hashable, Sendable {
      package let schemaVersion: Int
      package let cacheUUID: UUID
      package let imagePathDigest: String
      let imagePaths: [String]

      init(_ inventory: PrivateHeaderKitSharedCacheInventory) {
        schemaVersion = inventory.schemaVersion
        cacheUUID = inventory.cacheUUID
        imagePaths = inventory.imagePaths
        let digest = SHA256.hash(data: GenerationExecutor.canonicalFingerprintPayload(imagePaths))
        imagePathDigest = digest.map { String(format: "%02x", $0) }.joined()
      }
    }

    package struct PreparedPlan: Sendable {
      package let plan: Plan
      package let selectedTargetIDs: [String]
      package let sharedCacheCohort: SharedCacheCohort?
      let selectedTargets: [TargetDiscovery.DiscoveredTarget]

      init(
        plan: Plan,
        selectedTargets: [TargetDiscovery.DiscoveredTarget],
        sharedCacheCohort: SharedCacheCohort?
      ) {
        self.plan = plan
        self.selectedTargets = selectedTargets
        self.selectedTargetIDs = selectedTargets.map(\.candidate.identifier)
        self.sharedCacheCohort = sharedCacheCohort
      }

      package func withExecutionOptions(_ executionOptions: ExecutionOptions) -> PreparedPlan {
        var options = plan.options
        options.executionOptions = executionOptions
        return PreparedPlan(
          plan: Plan(source: plan.source, output: plan.output, options: options),
          selectedTargets: selectedTargets,
          sharedCacheCohort: sharedCacheCohort
        )
      }
    }

    let rawDumpRunner: RawDumpRunner
    let sharedCacheInventoryRunner: SharedCacheInventoryRunner
    private let runIDGenerator: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date

    package init(
      rawDumpRunner: @escaping RawDumpRunner,
      sharedCacheInventoryRunner: @escaping SharedCacheInventoryRunner,
      runIDGenerator: @escaping @Sendable () -> String = {
        "run-\(UUID().uuidString.lowercased())"
      },
      dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
      self.rawDumpRunner = rawDumpRunner
      self.sharedCacheInventoryRunner = sharedCacheInventoryRunner
      self.runIDGenerator = runIDGenerator
      self.dateProvider = dateProvider
    }

    package func prepare(_ plan: Plan) async throws -> PreparedPlan {
      try await Self.preparePlan(
        plan,
        sharedCacheInventoryRunner: sharedCacheInventoryRunner
      )
    }

    /// The unfinished all-target run that `run(_:progressReporter:)` would continue, if any.
    package func availableResumeSummary(
      for preparedPlan: PreparedPlan
    ) async throws -> ResumeSummary? {
      let plan = preparedPlan.plan
      guard plan.options.targetRequest.requestsAllTargets,
        plan.options.executionOptions.continuation != .restart
      else { return nil }
      guard let executionMode = plan.options.executionMode else {
        throw GenerationError.missingExecutionConfiguration("executionMode")
      }
      return try await withStore(for: plan) { store in
        let decision = try await Self.continuationDecision(
          plan: plan,
          targetIDs: preparedPlan.selectedTargetIDs,
          fingerprint: Self.planFingerprint(
            plan,
            executionMode: executionMode,
            sharedCacheCohort: preparedPlan.sharedCacheCohort
          ),
          store: store,
          at: dateProvider()
        )
        switch decision {
        case .generate: return nil
        case .resume(let summary), .requiresResume(let summary):
          return summary.isUnfinished ? summary : nil
        }
      }
    }

    package func run(
      _ preparedPlan: PreparedPlan,
      progressReporter: ProgressReporter? = nil
    ) async throws -> Result {
      let plan = preparedPlan.plan
      guard let helperURLs = plan.options.helperURLs else {
        throw GenerationError.missingExecutionConfiguration("helperURLs")
      }
      guard let executionMode = plan.options.executionMode else {
        throw GenerationError.missingExecutionConfiguration("executionMode")
      }
      try await validatePreparedCohort(preparedPlan)
      return try await withStore(for: plan) { store in
        try await run(
          preparedPlan,
          helperURLs: helperURLs,
          executionMode: executionMode,
          store: store,
          progressReporter: progressReporter
        )
      }
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate typealias Generation = PrivateHeaderGeneration

  fileprivate struct TargetExecution {
    let result: Generation.TargetAttemptResult
    /// Published path of each staged file. Empty unless the attempt completed.
    var stagedFiles: [Generation.ArtifactPath: URL] = [:]
    var warnings: [Generation.GenerationWarning] = []
  }

  /// Limits how many Objective-C metadata warnings one run prints. Every warning of a
  /// published target is still recorded in the state database.
  fileprivate struct ObjCMetadataWarningPresentationBudget {
    private var presented = Set<Generation.GenerationWarning>()
    private var omittedCount = 0

    mutating func consume(
      _ warnings: [Generation.GenerationWarning]
    ) -> [Generation.GenerationWarning] {
      warnings.filter { warning in
        guard !presented.contains(warning) else { return false }
        guard presented.count < maximumPresentedObjCMetadataWarningCount else {
          omittedCount += 1
          return false
        }
        presented.insert(warning)
        return true
      }
    }

    var aggregateWarning: Generation.GenerationWarning? {
      guard omittedCount > 0 else { return nil }
      return Generation.GenerationWarning(
        kind: "objc-metadata-warning",
        relativePath: "generation.sqlite",
        message:
          "\(omittedCount) additional Objective-C metadata warnings were hidden from"
          + " live output; all retained per-target details are persisted in generation.sqlite"
      )
    }
  }

  /// Opens the source's state database while holding its generation lease.
  fileprivate func withStore<Value>(
    for plan: Generation.Plan,
    _ body: (GenerationStore) async throws -> Value
  ) async throws -> Value {
    try FileManager.default.createDirectory(
      at: plan.stateDirectory,
      withIntermediateDirectories: true
    )
    let lockURL = plan.stateDirectory.appendingPathComponent("generation.lock", isDirectory: false)
    return try await GenerationLease.withExclusiveLease(at: lockURL) {
      let store = try GenerationStore(databaseURL: plan.databaseURL)
      try await store.interruptUnfinishedRuns(at: dateProvider())
      return try await body(store)
    }
  }

  fileprivate func run(
    _ preparedPlan: PreparedPlan,
    helperURLs: Generation.RawDumping.HelperURLs,
    executionMode: Generation.RawDumping.ExecutionMode,
    store: GenerationStore,
    progressReporter: ProgressReporter?
  ) async throws -> Generation.Result {
    let plan = preparedPlan.plan
    let targets = preparedPlan.selectedTargets
    let targetIDs = preparedPlan.selectedTargetIDs
    let stagingDirectory = plan.stateDirectory.appendingPathComponent("staging", isDirectory: true)
    // Staging left behind by a terminated run holds nothing that was published.
    try Self.removeItemIfPresent(at: stagingDirectory)

    let fingerprint = Self.planFingerprint(
      plan,
      executionMode: executionMode,
      sharedCacheCohort: preparedPlan.sharedCacheCohort
    )
    let targetIDsToRun: Set<String>
    switch try await Self.continuationDecision(
      plan: plan,
      targetIDs: targetIDs,
      fingerprint: fingerprint,
      store: store,
      at: dateProvider()
    ) {
    case .generate:
      targetIDsToRun = Set(targetIDs)
    case .resume(let summary):
      targetIDsToRun = Set(summary.targets.filter(\.shouldRun).map(\.targetID))
    case .requiresResume(let summary):
      throw Generation.GenerationError.resumeRequired(summary)
    }

    let runID = try Generation.RunID(runIDGenerator())
    try await store.beginRun(
      id: runID,
      plan: Generation.RunPlan(
        sourceIdentity: plan.source.storageIdentifier,
        fingerprint: fingerprint,
        targetIDs: targetIDs,
        isResumable: plan.options.targetRequest.requestsAllTargets
      ),
      at: dateProvider()
    )
    progressReporter?(.runStarted(runID: runID, totalTargetCount: targetIDsToRun.count))

    var warnings: [Generation.GenerationWarning] = []
    var warningBudget = ObjCMetadataWarningPresentationBudget()
    var generatedTargetIDs: [String] = []
    let snapshot: Generation.RunSnapshot
    var infrastructureError: (any Error)?
    do {
      var wasCancelled = false
      var startedCount = 0
      for target in targets {
        let targetID = target.candidate.identifier
        guard targetIDsToRun.contains(targetID) else {
          try await store.markSkipped(targetID: targetID, in: runID, at: dateProvider())
          continue
        }
        startedCount += 1
        try await store.beginTargetAttempt(
          targetID: targetID,
          displayName: target.candidate.displayName,
          kind: target.candidate.kind.rawValue,
          in: runID,
          at: dateProvider()
        )
        progressReporter?(
          .targetStarted(
            index: startedCount,
            total: targetIDsToRun.count,
            displayName: target.candidate.displayName
          ))

        let execution: TargetExecution
        if Task.isCancelled {
          execution = TargetExecution(result: Self.interruptedResult(target, at: dateProvider()))
        } else {
          execution = try await executeTarget(
            target,
            plan: plan,
            helperURLs: helperURLs,
            executionMode: executionMode,
            expectedCacheUUID: preparedPlan.sharedCacheCohort?.cacheUUID,
            stagingDirectory:
              stagingDirectory
              .appendingPathComponent(runID.rawValue, isDirectory: true)
              .appendingPathComponent(Self.stagingDirectoryName(for: targetID), isDirectory: true)
          )
        }

        if execution.result.status == .completed {
          try await publish(execution, to: plan.artifactDirectory, in: runID, store: store)
          generatedTargetIDs.append(targetID)
          let presentedWarnings = warningBudget.consume(execution.warnings)
          warnings += presentedWarnings
          presentedWarnings.forEach { progressReporter?(.warning($0)) }
        } else {
          try await store.recordTargetAttempt(execution.result, in: runID)
        }
        progressReporter?(
          .targetFinished(
            index: startedCount,
            total: targetIDsToRun.count,
            displayName: target.candidate.displayName,
            status: execution.result.status,
            failureSummary: execution.result.failureSummary
          ))
        if execution.result.status == .interrupted || Task.isCancelled {
          wasCancelled = true
          break
        }
      }
      snapshot = try await store.finishRun(
        runID,
        interrupted: wasCancelled || Task.isCancelled,
        at: dateProvider()
      )
    } catch {
      // The error is not one target's failure, so no later target is attempted.
      infrastructureError = error
      snapshot =
        Task.isCancelled
        ? try await store.finishRun(runID, interrupted: true, at: dateProvider())
        : try await store.failRun(runID, message: String(describing: error), at: dateProvider())
    }

    do {
      try Self.removeItemIfPresent(at: stagingDirectory)
    } catch {
      warnings.append(
        await recordWarning(
          Generation.GenerationWarning(
            kind: "cleanup-warning",
            relativePath: "staging",
            message: String(describing: error)
          ),
          runID: runID,
          store: store,
          progressReporter: progressReporter
        ))
    }
    if let aggregateWarning = warningBudget.aggregateWarning {
      warnings.append(
        await recordWarning(
          aggregateWarning,
          runID: runID,
          store: store,
          progressReporter: progressReporter
        ))
    }

    let summary = Generation.RunSummary(
      runID: runID,
      status: snapshot.status,
      targetCounts: snapshot.counts,
      artifactCounts: snapshot.publishedArtifactCounts,
      artifactDirectory: plan.artifactDirectory,
      stateDatabaseURL: plan.databaseURL,
      warnings: warnings,
      targetFailures: Self.targetFailures(snapshot.targets)
    )
    progressReporter?(.runFinished(summary))

    if snapshot.status == .interrupted {
      throw Generation.GenerationError.runInterrupted(.init(summary: summary))
    }
    if let infrastructureError {
      throw Generation.GenerationError.infrastructureFailed(
        .init(summary: summary, message: String(describing: infrastructureError))
      )
    }
    let failedTargetIDs = snapshot.targets
      .filter { $0.status != .completed && $0.status != .skipped }
      .map(\.targetID)
    if !failedTargetIDs.isEmpty {
      throw Generation.GenerationError.runFailed(
        .init(summary: summary, failedTargetIDs: failedTargetIDs)
      )
    }
    return Generation.Result(
      plan: plan,
      artifactDirectory: plan.artifactDirectory,
      generatedTargets: generatedTargetIDs.map(Generation.Target.generated(identifier:)),
      runID: runID,
      stateDatabaseURL: plan.databaseURL,
      targetCounts: snapshot.counts,
      artifactCounts: snapshot.publishedArtifactCounts,
      warnings: warnings
    )
  }

  /// Replaces the target's published files with a completed attempt's staged files.
  fileprivate func publish(
    _ execution: TargetExecution,
    to artifactDirectory: URL,
    in runID: Generation.RunID,
    store: GenerationStore
  ) async throws {
    let targetID = execution.result.targetID
    let staleArtifacts = Set(try await store.publishedArtifacts(targetID: targetID))
      .union(try await store.unpublishedAttemptArtifacts(targetID: targetID))
    try await store.recordArtifactsBeingPublished(
      execution.result.artifacts,
      targetID: targetID,
      in: runID
    )
    try Generation.TargetPublisher(artifactDirectory: artifactDirectory)
      .replace(staleArtifacts, with: execution.stagedFiles)
    try await store.recordPublishedTarget(
      execution.result,
      warnings: execution.warnings,
      in: runID
    )
  }

  /// Persists a run-level warning. A warning that cannot be stored is still reported.
  fileprivate func recordWarning(
    _ warning: Generation.GenerationWarning,
    runID: Generation.RunID,
    store: GenerationStore,
    progressReporter: ProgressReporter?
  ) async -> Generation.GenerationWarning {
    var warning = warning
    do {
      try await store.recordRunLog(runID: runID, warning: warning)
    } catch {
      warning = Generation.GenerationWarning(
        kind: warning.kind,
        relativePath: warning.relativePath,
        message: "\(warning.message); additionally failed to persist warning: \(error)"
      )
    }
    progressReporter?(.warning(warning))
    return warning
  }

  /// Dumps one target into its staging directory and collects the files to publish.
  ///
  /// A failure of the target itself is returned as its attempt result. An error that would
  /// repeat for every target, such as a helper from another build, is thrown.
  fileprivate func executeTarget(
    _ target: Generation.TargetDiscovery.DiscoveredTarget,
    plan: Generation.Plan,
    helperURLs: Generation.RawDumping.HelperURLs,
    executionMode: Generation.RawDumping.ExecutionMode,
    expectedCacheUUID: UUID?,
    stagingDirectory: URL
  ) async throws -> TargetExecution {
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    let invocation = Generation.RawDumping.makeInvocation(
      try Generation.RawDumping.Request(
        helperURLs: helperURLs,
        executionMode: executionMode,
        inputPath: Self.inputPath(for: target, executionMode: executionMode),
        stagingOutputDirectory: stagingDirectory,
        options: plan.options.rawDumpingOptions,
        expectedCacheUUID: expectedCacheUUID,
        logicalImagePath: plan.options.applicationSource?.logicalImagePath
      )
    )

    let rawResult: Generation.RawDumping.Result
    do {
      rawResult = try await rawDumpRunner(invocation)
    } catch is CancellationError {
      return TargetExecution(result: Self.interruptedResult(target, at: dateProvider()))
    } catch let error as Generation.RawDumping.ContractError {
      throw error
    } catch let error as Generation.RawDumping.ExecutionError {
      throw error
    } catch {
      return Self.failedExecution(
        target,
        status: Task.isCancelled ? .interrupted : .failed,
        summary: String(describing: error),
        at: dateProvider()
      )
    }
    guard rawResult.diagnosticsReport.producerVersion == plan.options.producerVersion else {
      throw Generation.GenerationError.producerVersionMismatch(
        expected: plan.options.producerVersion,
        actual: rawResult.diagnosticsReport.producerVersion
      )
    }
    if Task.isCancelled {
      return TargetExecution(result: Self.interruptedResult(target, at: dateProvider()))
    }

    let rawFailureSummary =
      rawResult.failureSummary ?? "raw dump exited with status \(rawResult.terminationStatus)"
    let artifactRoot = try Self.artifactRoot(for: target, layout: plan.options.layout)
    let staged: StagedArtifacts
    do {
      let runtimeRoot = plan.options.systemRoot?.path ?? ""
      if plan.options.includesAnalysisBinary, let application = plan.options.applicationSource {
        guard let binary = application.localBinaryURL else {
          throw Generation.GenerationError.missingExecutionConfiguration(
            "application analysis binary")
        }
        let directory = Self.stagedSourceDirectoryCandidates(
          for: target, in: stagingDirectory, runtimeRoot: runtimeRoot
        )[0].appendingPathComponent("Analysis", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: binary, to: directory.appendingPathComponent("Executable.macho"))
      }
      staged = try Self.collectStagedArtifacts(
        for: target,
        in: stagingDirectory,
        runtimeRoot: runtimeRoot,
        artifactRoot: artifactRoot,
        includesAnalysisBinary: plan.options.includesAnalysisBinary
      )
    } catch {
      return Self.failedExecution(
        target, status: .failed, summary: String(describing: error), at: dateProvider())
    }
    guard staged.files.values.contains(where: Self.isHeaderArtifact) else {
      return Self.failedExecution(
        target,
        status: .failed,
        summary: rawResult.succeeded ? "raw dump produced no header artifacts" : rawFailureSummary,
        at: dateProvider()
      )
    }
    let artifacts = staged.files.keys.sorted { $0.rawValue < $1.rawValue }
    guard rawResult.succeeded else {
      return Self.failedExecution(
        target,
        status: .partial,
        summary: rawFailureSummary,
        artifacts: artifacts,
        at: dateProvider()
      )
    }
    return TargetExecution(
      result: Generation.TargetAttemptResult(
        targetID: target.candidate.identifier,
        displayName: target.candidate.displayName,
        kind: target.candidate.kind.rawValue,
        status: .completed,
        artifacts: artifacts,
        completedAt: dateProvider()
      ),
      stagedFiles: staged.files,
      warnings: Self.objCMetadataWarnings(rawResult, relativePath: artifactRoot.rawValue)
    )
  }

  fileprivate static func failedExecution(
    _ target: Generation.TargetDiscovery.DiscoveredTarget,
    status: Generation.RunTargetStatus,
    summary: String,
    artifacts: [Generation.ArtifactPath] = [],
    at date: Date
  ) -> TargetExecution {
    TargetExecution(
      result: Generation.TargetAttemptResult(
        targetID: target.candidate.identifier,
        displayName: target.candidate.displayName,
        kind: target.candidate.kind.rawValue,
        status: status,
        artifacts: artifacts,
        failureSummary: summary,
        completedAt: date
      )
    )
  }

  fileprivate static func interruptedResult(
    _ target: Generation.TargetDiscovery.DiscoveredTarget,
    at date: Date
  ) -> Generation.TargetAttemptResult {
    failedExecution(target, status: .interrupted, summary: "cancelled", at: date).result
  }

  fileprivate static func objCMetadataWarnings(
    _ result: Generation.RawDumping.Result,
    relativePath: String
  ) -> [Generation.GenerationWarning] {
    var messages = result.diagnostics.map { "\($0.owner): \($0.degradation)" }
    if result.omittedDiagnosticCount > 0 {
      messages.append(
        "Objective-C metadata diagnostics: \(result.omittedDiagnosticCount)"
          + " additional diagnostics were omitted by the bounded helper report"
      )
    }
    return Set(messages).sorted().map {
      Generation.GenerationWarning(
        kind: "objc-metadata-warning", relativePath: relativePath, message: $0)
    }
  }

  fileprivate static func targetFailures(
    _ targets: [Generation.TargetAttemptSnapshot]
  ) -> [Generation.TargetFailure] {
    targets.compactMap { target in
      guard target.status == .partial || target.status == .failed else { return nil }
      return Generation.TargetFailure(
        targetID: target.targetID,
        displayName: target.displayName,
        status: target.status,
        message: target.failureSummary
      )
    }
  }

  /// A target identifier contains `/` and `:`, so it is percent-encoded into one path
  /// component.
  fileprivate static func stagingDirectoryName(for targetID: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._")
    return String(
      targetID.utf8.map { byte -> String in
        let scalar = Unicode.Scalar(byte)
        return byte < 0x80 && allowed.contains(scalar)
          ? String(scalar) : String(format: "%%%02X", byte)
      }.joined()
    )
  }

  fileprivate static func removeItemIfPresent(at url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
    }
  }
}
