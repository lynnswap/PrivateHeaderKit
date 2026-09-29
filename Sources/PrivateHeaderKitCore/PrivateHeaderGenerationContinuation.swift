import Foundation

extension PrivateHeaderGeneration {
  package enum Continuation: Hashable, Sendable {
    case automatic
    case resume
    case restart
  }

  package struct ExecutionOptions: Hashable, Sendable {
    package var continuation: Continuation
    package var allowsLegacyMigration: Bool

    package init(
      continuation: Continuation = .automatic,
      allowsLegacyMigration: Bool = false
    ) {
      self.continuation = continuation
      self.allowsLegacyMigration = allowsLegacyMigration
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
    currentArtifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    store: GenerationStore,
    at date: Date
  ) async throws -> PrivateHeaderGeneration.ContinuationDecision {
    let continuation = plan.options.executionOptions.continuation
    guard plan.options.targetRequest.requestsAllTargets, continuation != .restart,
      let checkpoint = try await store.allTargetCheckpoint(
        currentArtifactsByTarget: currentArtifactsByTarget
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
}
