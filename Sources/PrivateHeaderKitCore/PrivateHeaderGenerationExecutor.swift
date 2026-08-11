import CryptoKit
import Foundation
import PrivateHeaderKitHelperProtocol

extension PrivateHeaderGeneration {
  package struct GenerationExecutor: Sendable {
    private struct DeliberateFault: Error, @unchecked Sendable {
      let underlying: any Error
    }

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
    package typealias PublicationFaultInjector =
      @Sendable (
        PrivateHeaderGeneration.PublicationFaultPoint
      ) throws -> Void

    package struct SharedCacheCohort: Hashable, Sendable {
      package let schemaVersion: Int
      package let cacheUUID: UUID
      package let imagePathDigest: String
      fileprivate let imagePaths: [String]

      fileprivate init(_ inventory: PrivateHeaderKitSharedCacheInventory) {
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
      fileprivate let selectedTargets: [TargetDiscovery.DiscoveredTarget]

      fileprivate init(
        plan: Plan,
        selectedTargets: [TargetDiscovery.DiscoveredTarget],
        sharedCacheCohort: SharedCacheCohort?
      ) {
        self.plan = plan
        self.selectedTargets = selectedTargets
        self.selectedTargetIDs = selectedTargets.map(\.candidate.identifier)
        self.sharedCacheCohort = sharedCacheCohort
      }

      package func withResumeBehavior(_ resumeBehavior: ResumeBehavior) -> PreparedPlan {
        var options = plan.options
        options.resumeBehavior = resumeBehavior
        return PreparedPlan(
          plan: Plan(source: plan.source, output: plan.output, options: options),
          selectedTargets: selectedTargets,
          sharedCacheCohort: sharedCacheCohort
        )
      }
    }

    private let rawDumpRunner: RawDumpRunner
    private let sharedCacheInventoryRunner: SharedCacheInventoryRunner
    private let runIDGenerator: @Sendable () -> String
    private let generationIDGenerator: @Sendable () -> String
    private let dateProvider: @Sendable () -> Date
    private let storeFaultInjector: GenerationStore.FaultInjector
    private let publicationFaultInjector: PublicationFaultInjector

    package init(
      rawDumpRunner: @escaping RawDumpRunner,
      sharedCacheInventoryRunner: @escaping SharedCacheInventoryRunner,
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
      self.sharedCacheInventoryRunner = sharedCacheInventoryRunner
      self.runIDGenerator = runIDGenerator
      self.generationIDGenerator = generationIDGenerator
      self.dateProvider = dateProvider
      self.storeFaultInjector = storeFaultInjector
      self.publicationFaultInjector = publicationFaultInjector
    }

    package func prepare(_ plan: Plan) async throws -> PreparedPlan {
      try await Self.preparePlan(
        plan,
        sharedCacheInventoryRunner: sharedCacheInventoryRunner
      )
    }

    package func availableResumeSummary(
      for preparedPlan: PreparedPlan
    ) async throws -> ResumeSummary? {
      try await Self.resumeSummary(for: preparedPlan)
    }

    package func run(
      _ preparedPlan: PreparedPlan,
      progressReporter: ProgressReporter? = nil
    ) async throws -> Result {
      let plan = preparedPlan.plan
      let options = plan.options
      guard let helperURLs = options.helperURLs else {
        throw GenerationError.missingExecutionConfiguration("helperURLs")
      }
      guard let executionMode = options.executionMode else {
        throw GenerationError.missingExecutionConfiguration("executionMode")
      }
      try await validatePreparedCohort(preparedPlan)

      let publisher = try ArtifactPublisher(
        artifactBaseDirectory: plan.output.baseDirectory,
        sourceLabel: plan.source.storageIdentifier
      )
      try publisher.prepareForLease()
      return try await GenerationLease.withExclusiveLease(at: publisher.lockURL) {
        let artifactDirectory = Self.canonicalArtifactDirectory(
          outputBase: publisher.artifactBaseDirectory,
          sourceLabel: plan.source.storageIdentifier
        )
        let stateDirectory = Self.canonicalStateDirectory(
          outputBase: publisher.artifactBaseDirectory,
          sourceLabel: plan.source.storageIdentifier
        )
        let databaseURL = stateDirectory.appendingPathComponent(
          "generation.sqlite",
          isDirectory: false
        )
        let hadDatabase = try Self.regularFileExists(databaseURL)
        if !hadDatabase,
          !options.resumeBehavior.isFresh,
          let requirement = try Self.legacyMigrationRequirement(
            stateDirectory: stateDirectory,
            publisher: publisher
          )
        {
          throw GenerationError.legacyMigrationRequiresFresh(requirement)
        }
        let injectedStoreFault = storeFaultInjector
        let store = try GenerationStore(
          databaseURL: databaseURL,
          toolCompatibilityIdentity: options.toolCompatibilityIdentity,
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
          artifactDirectory: artifactDirectory,
          stateDirectory: stateDirectory,
          databaseURL: databaseURL,
          selectedTargets: preparedPlan.selectedTargets,
          sharedCacheCohort: preparedPlan.sharedCacheCohort,
          store: store,
          publisher: publisher,
          helperURLs: helperURLs,
          executionMode: executionMode,
          progressReporter: progressReporter
        )
      }
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate struct TargetExecution {
    let result: PrivateHeaderGeneration.TargetAttemptResult
    let completedFiles: [PrivateHeaderGeneration.ArtifactPath: URL]
    let stagedSourceDirectory: URL?
    let artifactRoot: PrivateHeaderGeneration.ArtifactPath?
  }

  fileprivate struct StagedArtifacts {
    let files: [PrivateHeaderGeneration.ArtifactPath: URL]
    let sourceDirectory: URL?
  }

  fileprivate enum PublishedTargetSource: Equatable {
    case currentGeneration
    case newerLiveOutput
    case unverifiedLiveOutput
    case unavailable
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
    artifactDirectory: URL,
    stateDirectory: URL,
    databaseURL: URL,
    selectedTargets: [PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget],
    sharedCacheCohort: SharedCacheCohort?,
    store: GenerationStore,
    publisher: ArtifactPublisher,
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    progressReporter: ProgressReporter?
  ) async throws -> PrivateHeaderGeneration.Result {
    if plan.options.resumeBehavior.isFresh {
      _ = try await store.bootstrapPublishedGenerationIfEmpty(
        sourceIdentity: plan.source.storageIdentifier,
        publication: publisher.inspect(),
        at: dateProvider()
      )
    }
    try await Self.recover(store: store, publisher: publisher, at: dateProvider())
    try await Self.recoverTargetReplacements(
      in: stateDirectory,
      artifactDirectory: artifactDirectory,
      currentMarker: try publisher.inspect().currentMarker,
      store: store
    )
    try publisher.cleanupStaging()
    try Self.cleanupStateStaging(in: stateDirectory)
    let publication = try publisher.inspect()
    let previousRunSnapshot = try await store.latestRunSnapshot()
    let previousAttemptedArtifactsByTarget = Dictionary(
      uniqueKeysWithValues: (previousRunSnapshot?.targets ?? []).map {
        ($0.targetID, $0.artifacts)
      }
    )
    let publishedTargetsByID = try await store.publishedTargetsByID()
    let publishedArtifactsByTarget = publishedTargetsByID.mapValues(\.artifacts)
    let liveArtifactStore = PrivateHeaderGeneration.ArtifactStore(
      artifactRoot: artifactDirectory
    )
    let targetIDsCoveredByCurrentGeneration = try await Self.targetIDsCoveredByCurrentGeneration(
      publication,
      store: store
    )
    let publishedTargetSources = try Self.publishedTargetSources(
      marker: publication.currentMarker,
      publishedTargetsByID: publishedTargetsByID,
      targetIDsCoveredByMarker: targetIDsCoveredByCurrentGeneration,
      liveArtifactStore: liveArtifactStore
    )
    try await Self.reconcileLiveArtifactDirectory(
      artifactDirectory,
      publication: publication,
      publishedDirectory: publisher.stableURL,
      publishedArtifactsByTarget: publishedArtifactsByTarget,
      publishedTargetSources: publishedTargetSources,
      stagingDirectory: Self.hydrationStagingDirectory(in: stateDirectory),
      store: store
    )
    let currentLiveArtifactsByTarget = try Self.availableLiveArtifactsByTarget(
      publishedArtifactsByTarget,
      publishedTargetSources: publishedTargetSources,
      under: artifactDirectory
    )

    if publication.stablePathState == .legacyDirectory,
      !plan.options.resumeBehavior.isFresh
    {
      throw PrivateHeaderGeneration.GenerationError.legacyMigrationRequiresFresh(
        .artifacts(path: publisher.stableURL.path)
      )
    }

    let targetIDs = selectedTargets.map(\.candidate.identifier)
    let fingerprint = Self.planFingerprint(
      plan,
      canonicalOutputBase: publisher.artifactBaseDirectory,
      executionMode: executionMode,
      sharedCacheCohort: sharedCacheCohort
    )
    let resumeSummary: PrivateHeaderGeneration.ResumeSummary?
    if plan.options.resumeBehavior.isFresh {
      resumeSummary = nil
    } else {
      resumeSummary = try await store.resumeSummary(
        planFingerprint: fingerprint,
        selectedTargetIDs: targetIDs,
        currentArtifactsByTarget: currentLiveArtifactsByTarget,
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
      toolCompatibilityIdentity: plan.options.toolCompatibilityIdentity
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

      let runStagingDirectory =
        stateDirectory
        .appendingPathComponent("staging", isDirectory: true)
        .appendingPathComponent(runID.rawValue, isDirectory: true)
      try Self.ensureEmptyDirectory(runStagingDirectory)
      let initialOpaquePaths = try publisher.opaquePathsForTargetValidation(
        in: publication,
        allowLegacyMigration: plan.options.resumeBehavior.isFresh,
        claimedBy: publishedArtifactsByTarget.values.flatMap { $0 }
      )
      var generatedTargetIDs: [String] = []
      var ownedArtifactsByTarget = publishedArtifactsByTarget
      var liveArtifactsByTarget = currentLiveArtifactsByTarget
      var unclaimedOpaquePaths = initialOpaquePaths
      var completedFilesByTarget: [String: [PrivateHeaderGeneration.ArtifactPath: URL]] = [:]
      var completedArtifactDigestsByTarget:
        [String: [PrivateHeaderGeneration.ArtifactPath: String]] = [:]
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
              status: .interrupted,
              failureSummary: nil
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
          expectedCacheUUID: sharedCacheCohort?.cacheUUID,
          stagingDirectory: targetStagingDirectory,
          publisher: publisher
        )

        if execution.result.status == .completed {
          guard let stagedSourceDirectory = execution.stagedSourceDirectory,
            let artifactRoot = execution.artifactRoot
          else {
            throw PrivateHeaderGeneration.StateError.corruptPublication(
              "completed target \(targetID) has no staged artifact source"
            )
          }
          let opaquePathsAfterReplacement = try publisher.validateTargetReplacement(
            targetID: targetID,
            artifacts: execution.result.artifacts,
            existingArtifactsByTarget: ownedArtifactsByTarget,
            opaquePaths: unclaimedOpaquePaths
          )
          let removalCandidates = PrivateHeaderGeneration.ArtifactStore.cleanupCandidates(
            manifestArtifacts: ownedArtifactsByTarget[targetID] ?? [],
            attemptedArtifacts: previousAttemptedArtifactsByTarget[targetID] ?? []
          )
          let artifactsToRemove = try liveArtifactStore.artifactsExcludingEquivalentPaths(
            removalCandidates,
            retainedArtifacts:
              ownedArtifactsByTarget
              .filter { $0.key != targetID }
              .values
              .flatMap { $0 }
              + opaquePathsAfterReplacement
          )
          let replacementDirectory = Self.replacementStagingDirectory(in: stateDirectory)
            .appendingPathComponent(runID.rawValue, isDirectory: true)
            .appendingPathComponent(
              Self.safeTargetDirectoryName(targetID),
              isDirectory: true
            )
          let replacement = try liveArtifactStore.prepareReplacement(
            stagingDirectory: targetStagingDirectory,
            stagedSourceDirectory: stagedSourceDirectory,
            artifactRoot: artifactRoot,
            artifacts: execution.result.artifacts,
            removing: artifactsToRemove,
            runID: runID,
            targetID: targetID,
            at: replacementDirectory
          )
          try await store.prepareTargetPublication(execution.result, in: runID)
          try liveArtifactStore.applyReplacement(replacement)
          do {
            try await store.recordPublishedTargetAttempt(
              execution.result,
              artifactDigests: replacement.artifactDigests,
              in: runID
            )
          } catch {
            let persistenceError = error
            do {
              try liveArtifactStore.rollbackReplacement(replacement)
            } catch {
              throw PrivateHeaderGeneration.ArtifactStoreError.replacementRollbackFailed(
                primary: String(describing: persistenceError),
                rollback: String(describing: error)
              )
            }
            throw persistenceError
          }
          ownedArtifactsByTarget[targetID] = execution.result.artifacts
          liveArtifactsByTarget[targetID] = execution.result.artifacts
          unclaimedOpaquePaths = opaquePathsAfterReplacement
          completedFilesByTarget[targetID] = execution.completedFiles
          completedArtifactDigestsByTarget[targetID] = replacement.artifactDigests
          generatedTargetIDs.append(targetID)
          do {
            try liveArtifactStore.finalizeReplacement(replacement)
          } catch {
            warnings.append(
              await surfacePostCommitWarning(
                runID: runID,
                kind: "cleanup-warning",
                relativePath:
                  "replacements/\(runID.rawValue)/\(Self.safeTargetDirectoryName(targetID))",
                error: error,
                store: store,
                progressReporter: progressReporter
              )
            )
          }
        } else {
          try await store.recordTargetAttempt(execution.result, in: runID)
        }
        progressReporter?(
          .targetFinished(
            index: executedIndex,
            total: targetIDsToRun.count,
            displayName: target.candidate.displayName,
            status: execution.result.status,
            failureSummary: execution.result.failureSummary
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
      let shouldReconcileInterruptedPublication =
        targetIDsToRun.isEmpty
        && previousRunSnapshot?.status != .completed
        && !liveArtifactsByTarget.isEmpty
      if generatedTargetIDs.isEmpty && !shouldReconcileInterruptedPublication {
        finalSnapshot = try await store.finishRunWithoutPublication(
          runID,
          at: dateProvider(),
          shouldInterrupt: { cancellationRequested() }
        )
        wasCancelled = finalSnapshot.status == .interrupted
      } else {
        let generatedTargetSet = Set(generatedTargetIDs)
        var snapshotFilesByTarget:
          [String: [PrivateHeaderGeneration.ArtifactPath: URL]] = [:]
        for (targetID, artifacts) in liveArtifactsByTarget
        where !generatedTargetSet.contains(targetID) {
          let sourceRoot: URL
          switch publishedTargetSources[targetID] {
          case .currentGeneration:
            sourceRoot = publisher.stableURL
          case .newerLiveOutput:
            guard let publishedTarget = publishedTargetsByID[targetID] else {
              throw PrivateHeaderGeneration.StateError.corruptPublication(
                "published target source is missing target \(targetID)"
              )
            }
            guard
              try liveArtifactStore.artifactsMatchDigests(
                artifacts,
                digests: publishedTarget.artifactDigests
              )
            else {
              throw PrivateHeaderGeneration.StateError.corruptPublication(
                "published target contents changed during generation: \(targetID)"
              )
            }
            sourceRoot = artifactDirectory
          case .unavailable:
            continue
          case .unverifiedLiveOutput:
            continue
          case nil:
            throw PrivateHeaderGeneration.StateError.corruptPublication(
              "published target source is missing for \(targetID)"
            )
          }
          snapshotFilesByTarget[targetID] = Dictionary(
            uniqueKeysWithValues: artifacts.map {
              ($0, Self.artifactURL($0, under: sourceRoot))
            }
          )
        }
        snapshotFilesByTarget.merge(completedFilesByTarget) { _, stagedFiles in
          stagedFiles
        }
        let initialDraft = try publisher.beginDraft(
          generationID: generationID,
          allowLegacyMigration: plan.options.resumeBehavior.isFresh
        )
        let draft = try publisher.replaceCompletedTargets(
          snapshotFilesByTarget,
          retiringOpaquePaths: ownedArtifactsByTarget.values.flatMap { $0 },
          in: initialDraft
        )
        var expectedArtifactDigestsByTarget = completedArtifactDigestsByTarget
        expectedArtifactDigestsByTarget.merge(
          Dictionary(
            uniqueKeysWithValues: snapshotFilesByTarget.keys.compactMap { targetID in
              guard publishedTargetSources[targetID] == .newerLiveOutput,
                !generatedTargetSet.contains(targetID),
                let publishedTarget = publishedTargetsByID[targetID]
              else {
                return nil
              }
              return (targetID, publishedTarget.artifactDigests)
            }
          )
        ) { _, publishedDigests in
          publishedDigests
        }
        let prepared = try publisher.prepareGeneration(
          draft,
          planFingerprint: fingerprint,
          expectedArtifactDigestsByTarget: expectedArtifactDigestsByTarget
        )
        let retirementCandidates = ownedArtifactsByTarget.compactMap { targetID, artifacts in
          generatedTargetSet.contains(targetID)
            || publishedTargetSources[targetID] != .unverifiedLiveOutput
            ? artifacts
            : nil
        }.flatMap { $0 }
        let retiringArtifacts = try liveArtifactStore.artifactsExcludingEquivalentPaths(
          retirementCandidates,
          retainedArtifacts: prepared.marker.artifactsByTarget.values.flatMap { $0 }
        )
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
        try Self.prepareLiveArtifactDirectory(
          artifactDirectory,
          from: prepared.finalDirectory,
          marker: prepared.marker,
          publishedArtifactsByTarget: prepared.marker.artifactsByTarget,
          publishedTargetSources: prepared.marker.artifactsByTarget.mapValues {
            _ in PublishedTargetSource.currentGeneration
          },
          stagingDirectory: Self.hydrationStagingDirectory(in: stateDirectory),
          retiringArtifacts: retiringArtifacts
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
        artifactDirectory: artifactDirectory,
        stateDatabaseURL: databaseURL,
        warnings: warnings,
        targetFailures: Self.targetFailures(finalSnapshot.targets)
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
        artifactDirectory: artifactDirectory,
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
        artifactDirectory: artifactDirectory,
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
    artifactDirectory: URL,
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
      try await Self.recover(
        store: store,
        publisher: publisher,
        at: dateProvider(),
        terminalReason: interruptionRequested
          ? .interrupted
          : .failed(message: String(describing: underlyingError))
      )
    }
    var warnings: [PrivateHeaderGeneration.GenerationWarning] = []
    try await Self.recoverTargetReplacements(
      in: stateDirectory,
      artifactDirectory: artifactDirectory,
      currentMarker: try publisher.inspect().currentMarker,
      store: store
    )
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
      artifactDirectory: artifactDirectory,
      stateDatabaseURL: databaseURL,
      warnings: warnings,
      targetFailures: Self.targetFailures(snapshot.targets)
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
    expectedCacheUUID: UUID?,
    stagingDirectory: URL,
    publisher: ArtifactPublisher
  ) async throws -> TargetExecution {
    let now = dateProvider()
    let invocation = PrivateHeaderGeneration.RawDumping.makeInvocation(
      try PrivateHeaderGeneration.RawDumping.Request(
        helperURLs: helperURLs,
        executionMode: executionMode,
        inputPath: Self.inputPath(for: target, executionMode: executionMode),
        stagingOutputDirectory: stagingDirectory,
        options: plan.options.rawDumpingOptions,
        expectedCacheUUID: expectedCacheUUID
      )
    )

    let rawResult: PrivateHeaderGeneration.RawDumping.Result
    do {
      rawResult = try await rawDumpRunner(invocation)
    } catch is CancellationError {
      return TargetExecution(
        result: Self.interruptedResult(target: target, at: dateProvider()),
        completedFiles: [:],
        stagedSourceDirectory: nil,
        artifactRoot: nil
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
        completedFiles: [:],
        stagedSourceDirectory: nil,
        artifactRoot: nil
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
        completedFiles: staged.files,
        stagedSourceDirectory: staged.sourceDirectory,
        artifactRoot: artifactRoot
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
      completedFiles: [:],
      stagedSourceDirectory: nil,
      artifactRoot: nil
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

  fileprivate static func reconcileLiveArtifactDirectory(
    _ directory: URL,
    publication: PrivateHeaderGeneration.PublicationSnapshot,
    publishedDirectory: URL,
    publishedArtifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    publishedTargetSources: [String: PublishedTargetSource],
    stagingDirectory: URL,
    store: GenerationStore
  ) async throws {
    let bootstrapReconciliation = try await store.pendingBootstrapReconciliation()
    if let bootstrapReconciliation {
      switch bootstrapReconciliation {
      case .empty:
        guard publication.currentGenerationID == nil else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "empty bootstrap reconciliation has a current generation"
          )
        }
      case .generation(let generationID):
        guard publication.currentGenerationID == generationID else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "bootstrap reconciliation generation \(generationID.rawValue) is not current"
          )
        }
      }
    }
    try prepareLiveArtifactDirectory(
      directory,
      from: publication.currentMarker == nil ? nil : publishedDirectory,
      marker: publication.currentMarker,
      publishedArtifactsByTarget: publishedArtifactsByTarget,
      publishedTargetSources: publishedTargetSources,
      stagingDirectory: stagingDirectory,
      validateUntrackedArtifacts: bootstrapReconciliation != nil
    )
    if let bootstrapReconciliation {
      try await store.completeBootstrapReconciliation(bootstrapReconciliation)
    }
  }

  fileprivate static func prepareLiveArtifactDirectory(
    _ directory: URL,
    from publishedDirectory: URL?,
    marker: PrivateHeaderGeneration.GenerationMarkerSnapshot?,
    publishedArtifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]] = [:],
    publishedTargetSources: [String: PublishedTargetSource] = [:],
    stagingDirectory: URL,
    validateUntrackedArtifacts: Bool = false,
    retiringArtifacts: [PrivateHeaderGeneration.ArtifactPath] = []
  ) throws {
    try ManagedFileSystem.ensureRealDirectory(directory)

    let liveArtifactStore = PrivateHeaderGeneration.ArtifactStore(artifactRoot: directory)
    if validateUntrackedArtifacts {
      let retainedArtifacts = marker.map {
        $0.artifactsByTarget.values.flatMap { $0 } + $0.opaquePaths
      } ?? []
      if let marker {
        try liveArtifactStore.validateExistingArtifacts(
          retainedArtifacts,
          digests: marker.contentDigests
        )
      }
      let untrackedArtifacts = try liveArtifactStore.artifactsExcludingEquivalentPaths(
        liveArtifactStore.inventoryRegularArtifacts(),
        retainedArtifacts: retainedArtifacts
      )
      if let firstUntrackedArtifact = untrackedArtifacts.first {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "live output contains unauthenticated artifact \(firstUntrackedArtifact.rawValue) after state loss"
        )
      }
    }

    guard let publishedDirectory, let marker else { return }
    let publishedOwnedArtifacts = publishedArtifactsByTarget.values.flatMap { $0 }
    let publishedArtifactSet = Set(publishedOwnedArtifacts)
    let supersededTargetIDs = Set(
      publishedTargetSources.compactMap { targetID, source in
        source == .currentGeneration ? nil : targetID
      }
    )
    let authoritativeArtifacts = Set(
      publishedTargetSources.compactMap { targetID, source in
        source == .currentGeneration ? marker.artifactsByTarget[targetID] : nil
      }.flatMap { $0 }
    )
    let staleArtifacts = try liveArtifactStore.artifactsExcludingEquivalentPaths(
      supersededTargetIDs.flatMap { marker.artifactsByTarget[$0] ?? [] },
      retainedArtifacts: publishedOwnedArtifacts
    )
    let unavailableArtifacts = publishedTargetSources.compactMap { targetID, source in
      source == .unavailable ? publishedArtifactsByTarget[targetID] : nil
    }.flatMap { $0 }
    let artifactsToRetire = PrivateHeaderGeneration.ArtifactStore.cleanupCandidates(
      manifestArtifacts: staleArtifacts + unavailableArtifacts + retiringArtifacts
    )
    if !artifactsToRetire.isEmpty {
      _ = try liveArtifactStore.cleanupManagedArtifacts(artifactsToRetire)
    }
    let publishedArtifacts = Set(
      marker.artifactsByTarget
        .filter { !supersededTargetIDs.contains($0.key) }
        .values
        .flatMap { $0 }
        + marker.opaquePaths.filter { !publishedArtifactSet.contains($0) }
    ).sorted { $0.rawValue < $1.rawValue }
    let isRecoveringInterruptedHydration = try prepareHydrationStagingDirectory(
      stagingDirectory
    )
    for artifact in publishedArtifacts {
      let source = artifactURL(artifact, under: publishedDirectory)
      guard try ManagedFileSystem.itemKind(at: source) == .regular else {
        throw ArtifactPublisher.PublisherError.missingArtifact(source.path)
      }
      let destination = artifactURL(artifact, under: directory)
      switch try ManagedFileSystem.itemKind(at: destination) {
      case nil:
        try liveArtifactStore.restoreArtifact(
          artifact,
          from: source,
          stagingDirectory: stagingDirectory,
          synchronizeExistingArtifact: isRecoveringInterruptedHydration
        )
      case .regular:
        if authoritativeArtifacts.contains(artifact) {
          try liveArtifactStore.restoreArtifact(
            artifact,
            from: source,
            stagingDirectory: stagingDirectory,
            synchronizeExistingArtifact: isRecoveringInterruptedHydration
          )
        }
      case .some(let kind):
        throw ManagedFileSystem.Failure.unexpectedKind(
          path: destination.path,
          expected: "regular file or missing",
          actual: kind
        )
      }
    }
    try FileManager.default.removeItem(at: stagingDirectory)
    try ManagedFileSystem.syncDirectory(stagingDirectory.deletingLastPathComponent())
  }

  fileprivate static func artifactURL(
    _ artifact: PrivateHeaderGeneration.ArtifactPath,
    under root: URL
  ) -> URL {
    artifact.rawValue.split(separator: "/").reduce(into: root) { url, component in
      url.appendPathComponent(String(component), isDirectory: false)
    }
  }

  fileprivate static func targetIDsCoveredByCurrentGeneration(
    _ publication: PrivateHeaderGeneration.PublicationSnapshot,
    store: GenerationStore
  ) async throws -> Set<String> {
    guard let generationID = publication.currentGenerationID else { return [] }
    return try await store.targetIDsCoveredByGeneration(generationID)
  }

  fileprivate static func publishedTargetSources(
    marker: PrivateHeaderGeneration.GenerationMarkerSnapshot?,
    publishedTargetsByID: [String: PrivateHeaderGeneration.TargetSnapshot],
    targetIDsCoveredByMarker: Set<String>,
    liveArtifactStore: PrivateHeaderGeneration.ArtifactStore
  ) throws -> [String: PublishedTargetSource] {
    try Dictionary(
      uniqueKeysWithValues: publishedTargetsByID.map { targetID, publishedTarget in
        guard targetIDsCoveredByMarker.contains(targetID) else {
          guard !publishedTarget.artifactDigests.isEmpty else {
            return (targetID, .unverifiedLiveOutput)
          }
          let matches = try liveArtifactStore.artifactsMatchDigests(
            publishedTarget.artifacts,
            digests: publishedTarget.artifactDigests
          )
          return (targetID, matches ? .newerLiveOutput : .unavailable)
        }
        guard let markerArtifacts = marker?.artifactsByTarget[targetID] else {
          return (targetID, .unavailable)
        }
        guard Set(markerArtifacts) == Set(publishedTarget.artifacts) else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "current generation artifacts disagree with published target \(targetID)"
          )
        }
        return (targetID, .currentGeneration)
      }
    )
  }

  fileprivate static func availableLiveArtifactsByTarget(
    _ artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    publishedTargetSources: [String: PublishedTargetSource],
    under root: URL
  ) throws -> [String: [PrivateHeaderGeneration.ArtifactPath]] {
    var available: [String: [PrivateHeaderGeneration.ArtifactPath]] = [:]
    for targetID in artifactsByTarget.keys.sorted() {
      guard let source = publishedTargetSources[targetID] else {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "published target \(targetID) has no artifact source"
        )
      }
      guard source == .currentGeneration || source == .newerLiveOutput else { continue }
      let artifacts = artifactsByTarget[targetID] ?? []
      var allArtifactsExist = true
      for artifact in artifacts {
        guard try ManagedFileSystem.itemKind(at: artifactURL(artifact, under: root)) == .regular
        else {
          allArtifactsExist = false
          break
        }
      }
      if allArtifactsExist {
        available[targetID] = artifacts
      }
    }
    return available
  }

  fileprivate static func targetFailures(
    _ targets: [PrivateHeaderGeneration.TargetAttemptSnapshot]
  ) -> [PrivateHeaderGeneration.TargetFailure] {
    targets.compactMap { target in
      guard target.status == .partial || target.status == .failed else { return nil }
      return PrivateHeaderGeneration.TargetFailure(
        targetID: target.targetID,
        displayName: target.displayName,
        status: target.status,
        message: target.failureSummary
      )
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  fileprivate func validatePreparedCohort(_ preparedPlan: PreparedPlan) async throws {
    guard let expectedCohort = preparedPlan.sharedCacheCohort else { return }
    guard let helperURLs = preparedPlan.plan.options.helperURLs else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("helperURLs")
    }
    guard let executionMode = preparedPlan.plan.options.executionMode else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
    }
    let actualCohort = try await Self.loadSharedCacheCohort(
      helperURLs: helperURLs,
      executionMode: executionMode,
      helperEnvironment: preparedPlan.plan.options.rawDumpingOptions.helperEnvironment,
      sharedCacheInventoryRunner: sharedCacheInventoryRunner
    )
    guard
      expectedCohort.cacheUUID == actualCohort.cacheUUID,
      expectedCohort.imagePathDigest == actualCohort.imagePathDigest
    else {
      throw PrivateHeaderGeneration.GenerationError.sharedCacheCohortChanged(
        expectedUUID: expectedCohort.cacheUUID,
        expectedImagePathDigest: expectedCohort.imagePathDigest,
        actualUUID: actualCohort.cacheUUID,
        actualImagePathDigest: actualCohort.imagePathDigest
      )
    }
  }

  fileprivate static func recover(
    store: GenerationStore,
    publisher: ArtifactPublisher,
    at date: Date,
    terminalReason: PrivateHeaderGeneration.RecoveryTerminalReason = .interrupted
  ) async throws {
    for _ in 0..<4 {
      let snapshot = try publisher.inspect()
      let action = try await store.recover(
        using: snapshot,
        at: date,
        terminalReason: terminalReason
      )
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

  fileprivate static func preparePlan(
    _ plan: PrivateHeaderGeneration.Plan,
    sharedCacheInventoryRunner: SharedCacheInventoryRunner
  ) async throws -> PreparedPlan {
    guard let systemRoot = plan.options.systemRoot else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("systemRoot")
    }
    guard let helperURLs = plan.options.helperURLs else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("helperURLs")
    }
    guard let executionMode = plan.options.executionMode else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
    }

    let sharedCacheCohort: SharedCacheCohort?
    if plan.options.rawDumpingOptions.useSharedCache {
      sharedCacheCohort = try await loadSharedCacheCohort(
        helperURLs: helperURLs,
        executionMode: executionMode,
        helperEnvironment: plan.options.rawDumpingOptions.helperEnvironment,
        sharedCacheInventoryRunner: sharedCacheInventoryRunner
      )
    } else {
      sharedCacheCohort = nil
    }

    let catalog = try PrivateHeaderGeneration.TargetDiscovery.discover(
      in: systemRoot,
      includeNestedChildren: plan.options.includeNestedChildren,
      sharedCacheImagePaths: sharedCacheCohort?.imagePaths ?? []
    )
    let selectedTargets = try selectedExecutionTargets(
      request: plan.options.targetRequest,
      catalog: catalog
    )
    guard !selectedTargets.isEmpty else {
      throw PrivateHeaderGeneration.GenerationError.noDiscoveredTargets(
        systemRoot: systemRoot.path
      )
    }
    return PreparedPlan(
      plan: plan,
      selectedTargets: selectedTargets,
      sharedCacheCohort: sharedCacheCohort
    )
  }

  fileprivate static func loadSharedCacheCohort(
    helperURLs: PrivateHeaderGeneration.RawDumping.HelperURLs,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    helperEnvironment: [String: String],
    sharedCacheInventoryRunner: SharedCacheInventoryRunner
  ) async throws -> SharedCacheCohort {
    try Task.checkCancellation()
    let invocation = PrivateHeaderGeneration.RawDumping.makeSharedCacheInventoryInvocation(
      helperURLs: helperURLs,
      executionMode: executionMode,
      helperEnvironment: helperEnvironment
    )
    let data = try await sharedCacheInventoryRunner(invocation)
    try Task.checkCancellation()
    let inventory = try JSONDecoder().decode(
      PrivateHeaderKitSharedCacheInventory.self,
      from: data
    )
    guard !inventory.imagePaths.isEmpty else {
      throw PrivateHeaderGeneration.GenerationError.emptySharedCacheInventory(
        cacheUUID: inventory.cacheUUID
      )
    }
    return SharedCacheCohort(inventory)
  }

  fileprivate static func resumeSummary(
    for preparedPlan: PreparedPlan
  ) async throws -> PrivateHeaderGeneration.ResumeSummary? {
    let plan = preparedPlan.plan
    guard let executionMode = plan.options.executionMode else {
      throw PrivateHeaderGeneration.GenerationError.missingExecutionConfiguration("executionMode")
    }
    guard !plan.options.resumeBehavior.isFresh else { return nil }
    let publisher = try ArtifactPublisher(
      artifactBaseDirectory: plan.output.baseDirectory,
      sourceLabel: plan.source.storageIdentifier
    )
    try publisher.prepareForLease()
    return try await GenerationLease.withExclusiveLease(at: publisher.lockURL) {
      let artifactDirectory = canonicalArtifactDirectory(
        outputBase: publisher.artifactBaseDirectory,
        sourceLabel: plan.source.storageIdentifier
      )
      let stateDirectory = canonicalStateDirectory(
        outputBase: publisher.artifactBaseDirectory,
        sourceLabel: plan.source.storageIdentifier
      )
      let databaseURL = stateDirectory.appendingPathComponent(
        "generation.sqlite",
        isDirectory: false
      )
      let hadDatabase = try regularFileExists(databaseURL)
      if !hadDatabase,
        !plan.options.resumeBehavior.isFresh,
        let requirement = try legacyMigrationRequirement(
          stateDirectory: stateDirectory,
          publisher: publisher
        )
      {
        throw PrivateHeaderGeneration.GenerationError.legacyMigrationRequiresFresh(requirement)
      }
      let store = try GenerationStore(
        databaseURL: databaseURL,
        toolCompatibilityIdentity: plan.options.toolCompatibilityIdentity
      )
      try await recover(store: store, publisher: publisher, at: Date())
      try await recoverTargetReplacements(
        in: stateDirectory,
        artifactDirectory: artifactDirectory,
        currentMarker: try publisher.inspect().currentMarker,
        store: store
      )
      try publisher.cleanupStaging()
      try cleanupStateStaging(in: stateDirectory)
      let publication = try publisher.inspect()
      if publication.stablePathState == .legacyDirectory,
        !plan.options.resumeBehavior.isFresh
      {
        throw PrivateHeaderGeneration.GenerationError.legacyMigrationRequiresFresh(
          .artifacts(path: publisher.stableURL.path)
        )
      }
      let publishedTargetsByID = try await store.publishedTargetsByID()
      let publishedArtifactsByTarget = publishedTargetsByID.mapValues(\.artifacts)
      let liveArtifactStore = PrivateHeaderGeneration.ArtifactStore(
        artifactRoot: artifactDirectory
      )
      let coveredTargetIDs = try await targetIDsCoveredByCurrentGeneration(
        publication,
        store: store
      )
      let publishedTargetSources = try Self.publishedTargetSources(
        marker: publication.currentMarker,
        publishedTargetsByID: publishedTargetsByID,
        targetIDsCoveredByMarker: coveredTargetIDs,
        liveArtifactStore: liveArtifactStore
      )
      try await reconcileLiveArtifactDirectory(
        artifactDirectory,
        publication: publication,
        publishedDirectory: publisher.stableURL,
        publishedArtifactsByTarget: publishedArtifactsByTarget,
        publishedTargetSources: publishedTargetSources,
        stagingDirectory: hydrationStagingDirectory(in: stateDirectory),
        store: store
      )
      let currentLiveArtifactsByTarget = try availableLiveArtifactsByTarget(
        publishedArtifactsByTarget,
        publishedTargetSources: publishedTargetSources,
        under: artifactDirectory
      )
      let summary = try await store.resumeSummary(
        planFingerprint: planFingerprint(
          plan,
          canonicalOutputBase: publisher.artifactBaseDirectory,
          executionMode: executionMode,
          sharedCacheCohort: preparedPlan.sharedCacheCohort
        ),
        selectedTargetIDs: preparedPlan.selectedTargetIDs,
        currentArtifactsByTarget: currentLiveArtifactsByTarget,
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
      if !files.isEmpty {
        return StagedArtifacts(files: files, sourceDirectory: candidate)
      }
    }
    return StagedArtifacts(files: [:], sourceDirectory: nil)
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
          firstPath: artifact.rawValue,
          firstOwner: targetIDForDiagnostic(sourceDirectory),
          secondPath: artifact.rawValue,
          secondOwner: targetIDForDiagnostic(sourceDirectory)
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
  package static func planFingerprint(
    _ plan: PrivateHeaderGeneration.Plan,
    canonicalOutputBase: URL,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    sharedCacheCohort: SharedCacheCohort?
  ) -> String {
    var components = [
      "privateheaderkit-plan-fingerprint-v2",
      plan.source.storageIdentifier,
      canonicalOutputBase.path,
      plan.options.layout.rawValue,
      plan.options.systemRoot?.standardizedFileURL.path ?? "",
      plan.options.toolCompatibilityIdentity,
      String(plan.options.includeNestedChildren),
      String(plan.options.rawDumpingOptions.skipExisting),
      String(plan.options.rawDumpingOptions.useSharedCache),
      String(plan.options.rawDumpingOptions.verbose),
      String(plan.options.rawDumpingOptions.preferRuntimeMetadata),
      plan.options.helperURLs?.host.standardizedFileURL.path ?? "",
      plan.options.helperURLs?.simulator.standardizedFileURL.path ?? "",
    ]
    if let sharedCacheCohort {
      components += [
        "loaded-shared-cache",
        String(sharedCacheCohort.schemaVersion),
        sharedCacheCohort.cacheUUID.uuidString.lowercased(),
        sharedCacheCohort.imagePathDigest,
      ]
    } else {
      components.append("filesystem-only")
    }
    switch executionMode {
    case .host:
      components.append("host")
    case .simulator(let deviceUDID, let runtimeRoot):
      components += ["simulator", deviceUDID, runtimeRoot]
    }
    for key in plan.options.rawDumpingOptions.helperEnvironment.keys.sorted() {
      components += [
        "environment",
        key,
        plan.options.rawDumpingOptions.helperEnvironment[key] ?? "",
      ]
    }
    let digest = SHA256.hash(data: canonicalFingerprintPayload(components))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func canonicalFingerprintPayload(_ components: [String]) -> Data {
    var payload = Data()
    for component in components {
      let length = UInt64(component.utf8.count)
      for shift in stride(from: 56, through: 0, by: -8) {
        payload.append(UInt8(truncatingIfNeeded: length >> shift))
      }
      payload.append(contentsOf: component.utf8)
    }
    return payload
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

  fileprivate static func prepareHydrationStagingDirectory(_ url: URL) throws -> Bool {
    do {
      try ManagedFileSystem.ensureRealDirectory(url.deletingLastPathComponent())
      guard let kind = try ManagedFileSystem.itemKind(at: url) else {
        try ManagedFileSystem.ensureRealDirectory(url)
        return false
      }
      guard kind == .directory else {
        throw ManagedFileSystem.Failure.unexpectedKind(
          path: url.path,
          expected: "directory or missing",
          actual: kind
        )
      }
      for child in try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: []
      ) {
        try FileManager.default.removeItem(at: child)
      }
      try ManagedFileSystem.syncDirectory(url)
      return true
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

  fileprivate static func replacementStagingDirectory(in stateDirectory: URL) -> URL {
    stateDirectory.appendingPathComponent("replacements", isDirectory: true)
  }

  fileprivate static func hydrationStagingDirectory(in stateDirectory: URL) -> URL {
    stateDirectory.appendingPathComponent("hydration", isDirectory: true)
  }

  fileprivate static func recoverTargetReplacements(
    in stateDirectory: URL,
    artifactDirectory: URL,
    currentMarker: PrivateHeaderGeneration.GenerationMarkerSnapshot?,
    store: GenerationStore
  ) async throws {
    let replacementsRoot = replacementStagingDirectory(in: stateDirectory)
    let artifactStore = PrivateHeaderGeneration.ArtifactStore(
      artifactRoot: artifactDirectory
    )
    let replacements = try PrivateHeaderGeneration.ArtifactStore.pendingReplacements(
      in: replacementsRoot,
      artifactRoot: artifactDirectory
    )
    for replacement in replacements {
      let publishedTarget = try await store.targetSnapshot(targetID: replacement.targetID)
      let wasCommitted =
        publishedTarget?.status == .completed
        && publishedTarget?.lastSuccessfulRunID == replacement.runID
        && Set(publishedTarget?.artifacts ?? []) == Set(replacement.incomingArtifacts)
        && publishedTarget?.artifactDigests == replacement.artifactDigests
      let isPublishedByCurrentGeneration = currentMarker.map { marker in
        guard Set(marker.artifactsByTarget[replacement.targetID] ?? [])
          == Set(replacement.incomingArtifacts)
        else {
          return false
        }
        return replacement.artifactDigests.allSatisfy { artifact, digest in
          marker.contentDigests[artifact] == digest
        }
      } ?? false
      if wasCommitted || isPublishedByCurrentGeneration {
        try artifactStore.finalizeReplacement(replacement)
      } else {
        try artifactStore.rollbackReplacement(replacement)
        try artifactStore.finalizeReplacement(replacement)
      }
    }
    try PrivateHeaderGeneration.ArtifactStore.cleanupReplacementStaging(replacementsRoot)
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

  fileprivate static func canonicalArtifactDirectory(outputBase: URL, sourceLabel: String) -> URL {
    outputBase
      .appendingPathComponent("generated-headers", isDirectory: true)
      .appendingPathComponent(sourceLabel, isDirectory: true)
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

  fileprivate static func legacyMigrationRequirement(
    stateDirectory: URL,
    publisher: ArtifactPublisher
  ) throws -> PrivateHeaderGeneration.LegacyMigrationRequirement? {
    let hasLegacyState = try legacyStateExists(in: stateDirectory)
    let hasLegacyArtifacts = try publisher.inspect().stablePathState == .legacyDirectory
    switch (hasLegacyState, hasLegacyArtifacts) {
    case (false, false):
      return nil
    case (true, false):
      return .state(path: stateDirectory.path)
    case (false, true):
      return .artifacts(path: publisher.stableURL.path)
    case (true, true):
      return .stateAndArtifacts(
        statePath: stateDirectory.path,
        artifactsPath: publisher.stableURL.path
      )
    }
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
