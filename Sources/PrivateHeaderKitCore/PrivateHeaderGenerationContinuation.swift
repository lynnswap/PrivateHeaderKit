import CryptoKit
import Foundation

extension PrivateHeaderGeneration {
  package enum Continuation: Hashable, Sendable {
    case automatic
    case resume
    case restart
  }

  package struct ExecutionOptions: Hashable, Sendable {
    package var continuation: Continuation

    package init(continuation: Continuation = .automatic) {
      self.continuation = continuation
    }
  }

  enum ContinuationDecision {
    case generate
    case resume(ResumeSummary)
    case requiresResume(ResumeSummary)
  }

  package struct AllTargetCheckpoint: Sendable {
    struct Publication: Sendable {
      let fingerprint: String
      let sequence: Int64
      let isAvailable: Bool
    }

    let run: RunSnapshot
    let sequence: Int64
    let publications: [String: Publication]

    // Removing output later does not undo completed generation work. Availability
    // matters when reusing that output, not when deciding whether a run finished.
    var hasUnfinishedWork: Bool {
      let attempts = Dictionary(uniqueKeysWithValues: run.targets.map { ($0.targetID, $0) })
      return run.targetIDs.contains { !wasPublished($0, attempt: attempts[$0]) }
    }

    func resumeSummary(selectedTargetIDs: [String], at date: Date) -> ResumeSummary {
      let attempts = Dictionary(uniqueKeysWithValues: run.targets.map { ($0.targetID, $0) })
      let decisions = selectedTargetIDs.map { targetID -> ResumeTargetDecision in
        let attempt = attempts[targetID]
        if wasPublished(targetID, attempt: attempt),
          let publication = publications[targetID],
          publication.isAvailable,
          publication.fingerprint == run.planFingerprint
        {
          return .init(targetID: targetID, status: .completed)
        }
        let status = attempt?.status ?? .pending
        return .init(
          targetID: targetID,
          status: status == .completed || status == .skipped ? .pending : status
        )
      }
      return ResumeSummary(
        latestRunID: run.id,
        startedAt: run.startedAt,
        updatedAt: run.endedAt ?? date,
        targets: decisions
      )
    }

    private func wasPublished(_ targetID: String, attempt: TargetAttemptSnapshot?) -> Bool {
      guard let publication = publications[targetID] else { return false }
      return publication.sequence >= sequence || attempt?.status == .skipped
    }
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  static func continuationDecision(
    plan: PrivateHeaderGeneration.Plan,
    targetIDs: [String],
    fingerprint: String,
    store: GenerationStore,
    at date: Date
  ) async throws -> PrivateHeaderGeneration.ContinuationDecision {
    let continuation = plan.options.executionOptions.continuation
    guard plan.options.targetRequest.requestsAllTargets, continuation != .restart else {
      return .generate
    }
    let availableTargetIDs = Self.targetIDsWithAllArtifactsPresent(
      try await store.publishedArtifactsByTarget(),
      in: plan.artifactDirectory
    )
    guard
      let checkpoint = try await store.allTargetCheckpoint(
        availableTargetIDs: availableTargetIDs
      )
    else { return .generate }

    if continuation == .automatic, !checkpoint.hasUnfinishedWork { return .generate }

    guard checkpoint.run.planFingerprint == fingerprint else {
      throw PrivateHeaderGeneration.GenerationError.incompatibleResume("plan fingerprint changed")
    }
    guard Set(checkpoint.run.targetIDs).isSubset(of: Set(targetIDs)) else {
      throw PrivateHeaderGeneration.GenerationError.incompatibleResume("selected target set shrank")
    }
    let summary = checkpoint.resumeSummary(selectedTargetIDs: targetIDs, at: date)
    return continuation == .resume ? .resume(summary) : .requiresResume(summary)
  }

  /// A published target counts as reusable only while every file it published still exists.
  private static func targetIDsWithAllArtifactsPresent(
    _ artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    in artifactDirectory: URL
  ) -> Set<String> {
    Set(
      artifactsByTarget.compactMap { targetID, artifacts in
        artifacts.allSatisfy {
          FileManager.default.fileExists(
            atPath: artifactDirectory.appending(path: $0.rawValue).path
          )
        } ? targetID : nil
      }
    )
  }
}

extension PrivateHeaderGeneration.GenerationExecutor {
  /// Identifies the inputs that decide what an all-target run produces. A run resumes only
  /// an earlier run with the same fingerprint.
  package static func planFingerprint(
    _ plan: PrivateHeaderGeneration.Plan,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode,
    sharedCacheCohort: SharedCacheCohort?
  ) -> String {
    var components = [
      "privateheaderkit-plan-fingerprint-v5",
      plan.source.storageIdentifier,
      plan.options.systemRoot?.standardizedFileURL.path ?? "",
      plan.options.producerVersion,
      String(plan.options.rawDumpingOptions.useSharedCache),
      String(plan.options.rawDumpingOptions.preferRuntimeMetadata),
    ]
    if plan.options.applicationSource != nil {
      components += ["recovered-application", "include-analysis-binary", String(plan.options.includesAnalysisBinary)]
    }
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
    case .simulator(_, let sourceRuntimeRoot, let runtime):
      components += [
        "simulator",
        sourceRuntimeRoot,
        runtime.version,
        runtime.build,
        runtime.identifier,
        runtime.runtimeRoot,
      ]
    case .ssh:
      components.append("iphoneos")
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

  static func canonicalFingerprintPayload(_ components: [String]) -> Data {
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
}
