import Foundation
import GRDB

package actor GenerationStore {
  package typealias FaultInjector =
    @Sendable (PrivateHeaderGeneration.StoreFaultPoint) throws -> Void

  private let databaseQueue: DatabaseQueue
  private let faultInjector: FaultInjector

  package init(
    databaseURL: URL,
    toolCompatibilityIdentity: String,
    faultInjector: @escaping FaultInjector = { _ in }
  ) throws {
    guard databaseURL.isFileURL else {
      throw PrivateHeaderGeneration.StateError.corruptPublication("database URL is not a file URL")
    }
    try Self.prepareDatabasePath(databaseURL)

    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.label = "PrivateHeaderKit.GenerationStore"
    let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    if try queue.read(Self.migrator.hasBeenSuperseded) {
      let unknownIdentifiers = try queue.read { db in
        try Self.migrator.appliedIdentifiers(db).subtracting(Self.migrator.migrations)
      }
      throw PrivateHeaderGeneration.StateError.unsupportedMigrations(
        unknownIdentifiers.sorted()
      )
    }
    try Self.migrator.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO metadata(key, value) VALUES ('toolCompatibilityIdentity', ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [toolCompatibilityIdentity]
      )
    }

    databaseQueue = queue
    self.faultInjector = faultInjector
  }

  package func appliedMigrationIdentifiers() throws -> [String] {
    try databaseQueue.read { db in
      try Self.migrator.completedMigrations(db)
    }
  }

  package func beginRun(
    id: PrivateHeaderGeneration.RunID,
    plan: PrivateHeaderGeneration.RunPlan,
    at date: Date
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
      if try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM runs WHERE status = ?",
        arguments: [PrivateHeaderGeneration.RunStatus.running.rawValue]) ?? 0 > 0
      {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: PrivateHeaderGeneration.RunStatus.running.rawValue,
          to: PrivateHeaderGeneration.RunStatus.running.rawValue
        )
      }

      try db.execute(
        sql: """
          INSERT INTO runs(
              id, sourceIdentity, planFingerprint, targetIDs, startedAt, endedAt, status
          ) VALUES (?, ?, ?, ?, ?, NULL, ?)
          """,
        arguments: [
          id.rawValue,
          plan.sourceIdentity,
          plan.fingerprint,
          try Self.encodeStrings(plan.targetIDs),
          date.timeIntervalSinceReferenceDate,
          PrivateHeaderGeneration.RunStatus.running.rawValue,
        ]
      )
      try db.execute(
        sql: "INSERT INTO runOrdering(runID) VALUES (?)",
        arguments: [id.rawValue]
      )
      for targetID in plan.targetIDs {
        try db.execute(
          sql: """
            INSERT INTO runTargets(
                runID, targetID, displayName, kind, status, failureSummary, artifactSet, updatedAt
            ) VALUES (?, ?, ?, '', ?, NULL, '[]', ?)
            """,
          arguments: [
            id.rawValue,
            targetID,
            targetID,
            PrivateHeaderGeneration.RunTargetStatus.pending.rawValue,
            date.timeIntervalSinceReferenceDate,
          ]
        )
      }
      return try Self.fetchRun(db, id: id)
    }
  }

  package func beginTargetAttempt(
    targetID: String,
    displayName: String,
    kind: String,
    in runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
      let status = try String.fetchOne(
        db,
        sql: "SELECT status FROM runTargets WHERE runID = ? AND targetID = ?",
        arguments: [runID.rawValue, targetID]
      )
      guard status == PrivateHeaderGeneration.RunTargetStatus.pending.rawValue else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "target attempt \(targetID)",
          from: status ?? "missing",
          to: PrivateHeaderGeneration.RunTargetStatus.running.rawValue
        )
      }
      try db.execute(
        sql: """
          UPDATE runTargets
          SET displayName = ?, kind = ?, status = ?, updatedAt = ?
          WHERE runID = ? AND targetID = ?
          """,
        arguments: [
          displayName,
          kind,
          PrivateHeaderGeneration.RunTargetStatus.running.rawValue,
          date.timeIntervalSinceReferenceDate,
          runID.rawValue,
          targetID,
        ]
      )
    }
  }

  package func prepareTargetPublication(
    _ result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    guard result.status == .completed else {
      throw PrivateHeaderGeneration.StateError.invalidTransition(
        entity: "target publication \(result.targetID)",
        from: result.status.rawValue,
        to: PrivateHeaderGeneration.RunTargetStatus.completed.rawValue
      )
    }
    try databaseQueue.write { db in
      let status = try String.fetchOne(
        db,
        sql: "SELECT status FROM runTargets WHERE runID = ? AND targetID = ?",
        arguments: [runID.rawValue, result.targetID]
      )
      guard status == PrivateHeaderGeneration.RunTargetStatus.running.rawValue else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "target publication \(result.targetID)",
          from: status ?? "missing",
          to: PrivateHeaderGeneration.RunTargetStatus.completed.rawValue
        )
      }
      try db.execute(
        sql: """
          UPDATE runTargets
          SET displayName = ?, kind = ?, artifactSet = ?, updatedAt = ?
          WHERE runID = ? AND targetID = ?
          """,
        arguments: [
          result.displayName,
          result.kind,
          try Self.encodeArtifacts(result.artifacts),
          result.completedAt.timeIntervalSinceReferenceDate,
          runID.rawValue,
          result.targetID,
        ]
      )
    }
  }

  package func recordTargetAttempt(
    _ result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    try databaseQueue.write { db in
      try Self.updateRunTarget(db, result: result, in: runID)
      try faultInjector(.afterRunTargetWrite)
    }
  }

  package func recordPublishedTargetAttempt(
    _ result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    guard result.status == .completed else {
      throw PrivateHeaderGeneration.StateError.invalidTransition(
        entity: "published target attempt \(result.targetID)",
        from: result.status.rawValue,
        to: PrivateHeaderGeneration.RunTargetStatus.completed.rawValue
      )
    }
    try databaseQueue.write { db in
      try Self.updateRunTarget(db, result: result, in: runID)
      try Self.upsertPublishedTarget(db, result: result, in: runID)
      try faultInjector(.afterRunTargetWrite)
    }
  }

  package func markSkipped(
    targetID: String,
    in runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
      try Self.transitionTarget(
        db,
        runID: runID,
        targetID: targetID,
        from: .pending,
        to: .skipped,
        failureSummary: nil,
        artifacts: [],
        at: date
      )
    }
  }

  package func preparePublication(
    generationID: PrivateHeaderGeneration.GenerationID,
    runID: PrivateHeaderGeneration.RunID,
    previousGenerationID: PrivateHeaderGeneration.GenerationID?,
    planFingerprint: String,
    artifactChecksum: String,
    at date: Date
  ) throws -> PrivateHeaderGeneration.PublicationIntent {
    try databaseQueue.write { db in
      guard try Self.runStatus(db, id: runID) == .running else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: try Self.runStatus(db, id: runID).rawValue,
          to: PrivateHeaderGeneration.PublicationState.prepared.rawValue
        )
      }
      let openCount =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM publicationIntents WHERE state IN (?, ?)",
          arguments: [
            PrivateHeaderGeneration.PublicationState.prepared.rawValue,
            PrivateHeaderGeneration.PublicationState.pointerPublished.rawValue,
          ]
        ) ?? 0
      guard openCount == 0 else {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "another publication intent is open")
      }
      try db.execute(
        sql: """
          INSERT INTO publicationIntents(
              generationID, runID, previousGenerationID, state,
              planFingerprint, artifactChecksum, createdAt, completedAt
          ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
          """,
        arguments: [
          generationID.rawValue,
          runID.rawValue,
          previousGenerationID?.rawValue,
          PrivateHeaderGeneration.PublicationState.prepared.rawValue,
          planFingerprint,
          artifactChecksum,
          date.timeIntervalSinceReferenceDate,
        ]
      )
      try db.execute(
        sql: "INSERT INTO publicationOrdering(generationID) VALUES (?)",
        arguments: [generationID.rawValue]
      )
      try faultInjector(.afterPublicationIntentWrite)
      return try Self.fetchPublicationIntent(db, generationID: generationID)
    }
  }

  package func markPointerPublished(
    _ generationID: PrivateHeaderGeneration.GenerationID
  ) throws {
    try databaseQueue.write { db in
      let intent = try Self.fetchPublicationIntent(db, generationID: generationID)
      guard intent.state == .prepared else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "publication",
          from: intent.state.rawValue,
          to: PrivateHeaderGeneration.PublicationState.pointerPublished.rawValue
        )
      }
      try db.execute(
        sql: "UPDATE publicationIntents SET state = ? WHERE generationID = ?",
        arguments: [
          PrivateHeaderGeneration.PublicationState.pointerPublished.rawValue,
          generationID.rawValue,
        ]
      )
    }
  }

  package func completePublication(
    _ generationID: PrivateHeaderGeneration.GenerationID,
    at date: Date,
    shouldInterrupt: @escaping @Sendable () -> Bool = { false }
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
      let intent = try Self.fetchPublicationIntent(db, generationID: generationID)
      guard intent.state == .pointerPublished else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "publication",
          from: intent.state.rawValue,
          to: PrivateHeaderGeneration.PublicationState.committed.rawValue
        )
      }
      return try Self.finalizePublication(
        db,
        intent: intent,
        at: date,
        shouldInterrupt: shouldInterrupt,
        faultInjector: faultInjector
      )
    }
  }

  package func finishRunWithoutPublication(
    _ runID: PrivateHeaderGeneration.RunID,
    at date: Date,
    shouldInterrupt: @escaping @Sendable () -> Bool = { false }
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    return try databaseQueue.write { db in
      guard try Self.runStatus(db, id: runID) == .running else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: try Self.runStatus(db, id: runID).rawValue,
          to: "terminal"
        )
      }
      try Self.interruptRunningTargets(db, runID: runID, at: date)
      try faultInjector(.beforeTerminalRunCommit)
      if shouldInterrupt() {
        try Self.applyInterruptionOverride(db, runID: runID)
      }
      let status = try Self.finalRunStatus(db, runID: runID)
      try db.execute(
        sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
        arguments: [status.rawValue, date.timeIntervalSinceReferenceDate, runID.rawValue]
      )
      return try Self.fetchRun(db, id: runID)
    }
  }

  package func markInterrupted(
    _ runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
      let status = try Self.runStatus(db, id: runID)
      if status == .interrupted {
        return try Self.fetchRun(db, id: runID)
      }
      guard status == .running else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: status.rawValue,
          to: PrivateHeaderGeneration.RunStatus.interrupted.rawValue
        )
      }
      try Self.interruptRunningTargets(db, runID: runID, at: date)
      try db.execute(
        sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
        arguments: [
          PrivateHeaderGeneration.RunStatus.interrupted.rawValue,
          date.timeIntervalSinceReferenceDate,
          runID.rawValue,
        ]
      )
      return try Self.fetchRun(db, id: runID)
    }
  }

  package func failRun(
    _ runID: PrivateHeaderGeneration.RunID,
    message: String,
    at date: Date
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
      guard try Self.runStatus(db, id: runID) == .running else {
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: try Self.runStatus(db, id: runID).rawValue,
          to: PrivateHeaderGeneration.RunStatus.failed.rawValue
        )
      }
      try db.execute(
        sql: """
          UPDATE runTargets
          SET status = ?, failureSummary = COALESCE(failureSummary, ?), updatedAt = ?
          WHERE runID = ? AND status = ?
          """,
        arguments: [
          PrivateHeaderGeneration.RunTargetStatus.failed.rawValue,
          message,
          date.timeIntervalSinceReferenceDate,
          runID.rawValue,
          PrivateHeaderGeneration.RunTargetStatus.running.rawValue,
        ]
      )
      try db.execute(
        sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
        arguments: [
          PrivateHeaderGeneration.RunStatus.failed.rawValue,
          date.timeIntervalSinceReferenceDate,
          runID.rawValue,
        ]
      )
      return try Self.fetchRun(db, id: runID)
    }
  }

  package func requestInterruption(
    _ runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
      let status = try Self.runStatus(db, id: runID)
      guard status == .running else {
        if status == .interrupted { return }
        throw PrivateHeaderGeneration.StateError.invalidTransition(
          entity: "run",
          from: status.rawValue,
          to: PrivateHeaderGeneration.RunStatus.interrupted.rawValue
        )
      }
      try Self.interruptRunningTargets(db, runID: runID, at: date)
      try db.execute(
        sql: "UPDATE runs SET terminalStatusOverride = ? WHERE id = ?",
        arguments: [PrivateHeaderGeneration.RunStatus.interrupted.rawValue, runID.rawValue]
      )
    }
  }

  package func recover(
    using publication: PrivateHeaderGeneration.PublicationSnapshot,
    at date: Date,
    terminalReason: PrivateHeaderGeneration.RecoveryTerminalReason = .interrupted
  ) throws -> PrivateHeaderGeneration.RecoveryAction {
    try databaseQueue.write { db in
      guard let intent = try Self.fetchLatestPublicationIntent(db) else {
        try Self.interruptDanglingRuns(db, at: date)
        return .recognized(publication.currentGenerationID)
      }

      if intent.state == .committed {
        guard publication.currentGenerationID == intent.generationID,
          publication.stablePathState == .managed,
          let marker = publication.currentMarker,
          marker.planFingerprint == intent.planFingerprint,
          marker.artifactChecksum == intent.artifactChecksum
        else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "committed generation \(intent.generationID.rawValue) does not match current publication"
          )
        }
        try Self.interruptDanglingRuns(db, at: date)
        return .none
      }
      if intent.state == .aborted {
        guard publication.currentGenerationID == intent.previousGenerationID else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "aborted generation \(intent.generationID.rawValue) does not preserve its previous current generation"
          )
        }
        switch (intent.previousGenerationID, publication.stablePathState) {
        case (nil, .absent), (nil, .legacyDirectory):
          break
        case (.some, .managed):
          guard publication.currentMarker != nil else {
            throw PrivateHeaderGeneration.StateError.corruptPublication(
              "aborted generation \(intent.generationID.rawValue) has no marker for its previous current generation"
            )
          }
        case (nil, .managed), (.some, .absent), (.some, .legacyDirectory):
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "aborted generation \(intent.generationID.rawValue) has inconsistent stable publication state"
          )
        }
        try Self.interruptDanglingRuns(db, at: date)
        if publication.validGenerationIDs.contains(intent.generationID) {
          return .discardGeneration(intent.generationID)
        }
        return .recognized(publication.currentGenerationID)
      }

      guard publication.validGenerationIDs.contains(intent.generationID) else {
        if publication.currentGenerationID == intent.previousGenerationID,
          intent.state == .prepared
        {
          try Self.abortIntent(
            db,
            intent: intent,
            terminalReason: terminalReason,
            at: date
          )
          return .discardGeneration(intent.generationID)
        }
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "open intent generation \(intent.generationID.rawValue) has no valid marker"
        )
      }

      if publication.currentGenerationID == intent.generationID {
        guard let marker = publication.currentMarker,
          marker.planFingerprint == intent.planFingerprint,
          marker.artifactChecksum == intent.artifactChecksum
        else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "current generation marker does not match publication intent"
          )
        }
        guard publication.stablePathState == .managed else {
          return .completeStablePointer(intent.generationID)
        }
        if intent.state == .prepared {
          try db.execute(
            sql: "UPDATE publicationIntents SET state = ? WHERE generationID = ?",
            arguments: [
              PrivateHeaderGeneration.PublicationState.pointerPublished.rawValue,
              intent.generationID.rawValue,
            ]
          )
        }
        let refreshed = try Self.fetchPublicationIntent(db, generationID: intent.generationID)
        _ = try Self.finalizePublication(
          db,
          intent: refreshed,
          at: date,
          shouldInterrupt: { false },
          faultInjector: { _ in }
        )
        return .rolledForward(intent.generationID)
      }

      if publication.currentGenerationID == intent.previousGenerationID {
        guard intent.state == .prepared else {
          throw PrivateHeaderGeneration.StateError.corruptPublication(
            "pointerPublished intent does not match current generation"
          )
        }
        try Self.abortIntent(
          db,
          intent: intent,
          terminalReason: terminalReason,
          at: date
        )
        return .discardGeneration(intent.generationID)
      }

      throw PrivateHeaderGeneration.StateError.corruptPublication(
        "current pointer does not match open intent or its previous generation"
      )
    }
  }

  package func publicationIntent(
    generationID: PrivateHeaderGeneration.GenerationID
  ) throws -> PrivateHeaderGeneration.PublicationIntent? {
    try databaseQueue.read { db in
      try Self.fetchPublicationIntentIfPresent(db, generationID: generationID)
    }
  }

  package func latestRunSnapshot() throws -> PrivateHeaderGeneration.RunSnapshot? {
    try databaseQueue.read { db in
      guard
        let id = try String.fetchOne(
          db,
          sql: """
            SELECT runs.id
            FROM runs JOIN runOrdering ON runOrdering.runID = runs.id
            ORDER BY runOrdering.sequence DESC
            LIMIT 1
            """
        )
      else {
        return nil
      }
      return try Self.fetchRun(db, id: PrivateHeaderGeneration.RunID(id))
    }
  }

  package func runSnapshot(
    _ runID: PrivateHeaderGeneration.RunID
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.read { db in
      try Self.fetchRun(db, id: runID)
    }
  }

  package func targetSnapshot(
    targetID: String
  ) throws -> PrivateHeaderGeneration.TargetSnapshot? {
    try databaseQueue.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM targets WHERE targetID = ?",
          arguments: [targetID]
        )
      else {
        return nil
      }
      return try Self.targetSnapshot(row)
    }
  }

  package func publishedArtifactsByTarget()
    throws -> [String: [PrivateHeaderGeneration.ArtifactPath]]
  {
    try databaseQueue.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT * FROM targets").map { row in
          let snapshot = try Self.targetSnapshot(row)
          return (snapshot.targetID, snapshot.artifacts)
        }
      )
    }
  }

  package func recordRunLog(
    runID: PrivateHeaderGeneration.RunID,
    kind: String,
    relativePath: String,
    message: String
  ) throws {
    guard PrivateHeaderGeneration.ArtifactPath.isSafeRelativePath(relativePath) else {
      throw PrivateHeaderGeneration.StateError.invalidArtifactPath(relativePath)
    }
    try faultInjector(.beforeRunLogWrite)
    try databaseQueue.write { db in
      guard
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM runs WHERE id = ?",
          arguments: [runID.rawValue]
        ) == 1
      else {
        throw PrivateHeaderGeneration.StateError.missingRun(runID)
      }
      try db.execute(
        sql: "INSERT INTO runLogs(runID, kind, relativePath, message) VALUES (?, ?, ?, ?)",
        arguments: [runID.rawValue, kind, relativePath, message]
      )
    }
  }

  package func resumeSummary(
    planFingerprint: String,
    selectedTargetIDs: [String],
    currentArtifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    at date: Date
  ) throws -> PrivateHeaderGeneration.ResumeSummary? {
    try databaseQueue.read { db in
      guard
        let latestID = try String.fetchOne(
          db,
          sql: """
            SELECT runs.id
            FROM runs JOIN runOrdering ON runOrdering.runID = runs.id
            ORDER BY runOrdering.sequence DESC
            LIMIT 1
            """
        )
      else {
        return nil
      }
      let run = try Self.fetchRun(db, id: PrivateHeaderGeneration.RunID(latestID))
      guard run.planFingerprint == planFingerprint else {
        throw PrivateHeaderGeneration.GenerationError.incompatibleResume("plan fingerprint changed")
      }
      let previousTargets = Set(run.targetIDs)
      let selectedTargets = Set(selectedTargetIDs)
      guard previousTargets.isSubset(of: selectedTargets) else {
        throw PrivateHeaderGeneration.GenerationError.incompatibleResume(
          "selected target set shrank")
      }

      let attempts = Dictionary(uniqueKeysWithValues: run.targets.map { ($0.targetID, $0) })
      let publishedTargets = try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT * FROM targets").map {
          let snapshot = try Self.targetSnapshot($0)
          return (snapshot.targetID, snapshot)
        }
      )
      let decisions = selectedTargetIDs.map {
        targetID -> PrivateHeaderGeneration.ResumeTargetDecision in
        guard let attempt = attempts[targetID] else {
          return .init(targetID: targetID, status: .pending)
        }
        let currentArtifacts = currentArtifactsByTarget[targetID].map(Set.init)
        let publishedTarget = publishedTargets[targetID]
        if attempt.status == .completed,
          publishedTarget?.lastSuccessfulRunID == run.id,
          Set(publishedTarget?.artifacts ?? []) == Set(attempt.artifacts),
          currentArtifacts == Set(attempt.artifacts)
        {
          return .init(targetID: targetID, status: .completed)
        }
        if attempt.status == .skipped,
          publishedTarget?.status == .completed,
          currentArtifacts == Set(publishedTarget?.artifacts ?? [])
        {
          return .init(targetID: targetID, status: .completed)
        }
        return .init(
          targetID: targetID,
          status: attempt.status == .completed || attempt.status == .skipped
            ? .pending
            : attempt.status
        )
      }
      return PrivateHeaderGeneration.ResumeSummary(
        latestRunID: run.id,
        startedAt: run.startedAt,
        updatedAt: run.endedAt ?? date,
        targets: decisions
      )
    }
  }
}

extension GenerationStore {
  fileprivate static func updateRunTarget(
    _ db: Database,
    result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    let status = try String.fetchOne(
      db,
      sql: "SELECT status FROM runTargets WHERE runID = ? AND targetID = ?",
      arguments: [runID.rawValue, result.targetID]
    )
    guard status == PrivateHeaderGeneration.RunTargetStatus.running.rawValue else {
      throw PrivateHeaderGeneration.StateError.invalidTransition(
        entity: "target attempt \(result.targetID)",
        from: status ?? "missing",
        to: result.status.rawValue
      )
    }
    try db.execute(
      sql: """
        UPDATE runTargets
        SET displayName = ?, kind = ?, status = ?, failureSummary = ?, artifactSet = ?, updatedAt = ?
        WHERE runID = ? AND targetID = ?
        """,
      arguments: [
        result.displayName,
        result.kind,
        result.status.rawValue,
        result.failureSummary,
        try encodeArtifacts(result.artifacts),
        result.completedAt.timeIntervalSinceReferenceDate,
        runID.rawValue,
        result.targetID,
      ]
    )
  }

  fileprivate static func upsertPublishedTarget(
    _ db: Database,
    result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO targets(targetID, lastSuccessfulRunID, status, artifactSet, updatedAt)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(targetID) DO UPDATE SET
            lastSuccessfulRunID = excluded.lastSuccessfulRunID,
            status = excluded.status,
            artifactSet = excluded.artifactSet,
            updatedAt = excluded.updatedAt
        """,
      arguments: [
        result.targetID,
        runID.rawValue,
        PrivateHeaderGeneration.RunTargetStatus.completed.rawValue,
        try encodeArtifacts(result.artifacts),
        result.completedAt.timeIntervalSinceReferenceDate,
      ]
    )
  }

  fileprivate static func prepareDatabasePath(_ databaseURL: URL) throws {
    do {
      try ManagedFileSystem.ensureRealDirectory(databaseURL.deletingLastPathComponent())
      try ManagedFileSystem.requireRegularFileOrMissing(databaseURL)
      for suffix in ["-wal", "-shm", "-journal"] {
        try ManagedFileSystem.requireRegularFileOrMissing(
          URL(fileURLWithPath: databaseURL.path + suffix)
        )
      }
    } catch let error as ManagedFileSystem.Failure {
      throw PrivateHeaderGeneration.StateError.corruptPublication(error.description)
    }
  }

  fileprivate static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-generation-state") { db in
      try db.execute(
        sql: """
          CREATE TABLE metadata (
              key TEXT PRIMARY KEY NOT NULL,
              value TEXT NOT NULL
          );
          CREATE TABLE runs (
              id TEXT PRIMARY KEY NOT NULL,
              sourceIdentity TEXT NOT NULL,
              planFingerprint TEXT NOT NULL,
              targetIDs TEXT NOT NULL,
              startedAt DOUBLE NOT NULL,
              endedAt DOUBLE,
              status TEXT NOT NULL,
              terminalStatusOverride TEXT
          );
          CREATE TABLE runTargets (
              runID TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
              targetID TEXT NOT NULL,
              displayName TEXT NOT NULL,
              kind TEXT NOT NULL,
              status TEXT NOT NULL,
              failureSummary TEXT,
              artifactSet TEXT NOT NULL,
              updatedAt DOUBLE NOT NULL,
              PRIMARY KEY (runID, targetID)
          );
          CREATE TABLE targets (
              targetID TEXT PRIMARY KEY NOT NULL,
              lastSuccessfulRunID TEXT NOT NULL REFERENCES runs(id),
              status TEXT NOT NULL,
              artifactSet TEXT NOT NULL,
              updatedAt DOUBLE NOT NULL
          );
          CREATE TABLE publicationIntents (
              generationID TEXT PRIMARY KEY NOT NULL,
              runID TEXT NOT NULL REFERENCES runs(id),
              previousGenerationID TEXT,
              state TEXT NOT NULL,
              planFingerprint TEXT NOT NULL,
              artifactChecksum TEXT NOT NULL,
              createdAt DOUBLE NOT NULL,
              completedAt DOUBLE
          );
          """)
    }
    migrator.registerMigration("v2-run-logs-and-indexes") { db in
      try db.execute(
        sql: """
          CREATE TABLE runLogs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              runID TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              relativePath TEXT NOT NULL,
              message TEXT NOT NULL
          );
          CREATE INDEX runTargets_status ON runTargets(status);
          CREATE INDEX publicationIntents_state ON publicationIntents(state);
          """)
    }
    migrator.registerMigration("v3-causal-ordering") { db in
      try db.execute(
        sql: """
          CREATE TABLE runOrdering (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              runID TEXT NOT NULL UNIQUE REFERENCES runs(id) ON DELETE CASCADE
          );
          INSERT INTO runOrdering(runID) SELECT id FROM runs ORDER BY rowid;
          CREATE TABLE publicationOrdering (
              sequence INTEGER PRIMARY KEY AUTOINCREMENT,
              generationID TEXT NOT NULL UNIQUE
                  REFERENCES publicationIntents(generationID) ON DELETE CASCADE
          );
          INSERT INTO publicationOrdering(generationID)
              SELECT generationID FROM publicationIntents ORDER BY rowid;
          """)
    }
    return migrator
  }

  fileprivate static func runStatus(
    _ db: Database,
    id: PrivateHeaderGeneration.RunID
  ) throws -> PrivateHeaderGeneration.RunStatus {
    guard
      let raw = try String.fetchOne(
        db,
        sql: "SELECT status FROM runs WHERE id = ?",
        arguments: [id.rawValue]
      )
    else {
      throw PrivateHeaderGeneration.StateError.missingRun(id)
    }
    guard let status = PrivateHeaderGeneration.RunStatus(rawValue: raw) else {
      throw PrivateHeaderGeneration.StateError.corruptPublication("unknown run status \(raw)")
    }
    return status
  }

  fileprivate static func transitionTarget(
    _ db: Database,
    runID: PrivateHeaderGeneration.RunID,
    targetID: String,
    from: PrivateHeaderGeneration.RunTargetStatus,
    to: PrivateHeaderGeneration.RunTargetStatus,
    failureSummary: String?,
    artifacts: [PrivateHeaderGeneration.ArtifactPath],
    at date: Date
  ) throws {
    let rawStatus = try String.fetchOne(
      db,
      sql: "SELECT status FROM runTargets WHERE runID = ? AND targetID = ?",
      arguments: [runID.rawValue, targetID]
    )
    guard rawStatus == from.rawValue else {
      throw PrivateHeaderGeneration.StateError.invalidTransition(
        entity: "target attempt \(targetID)",
        from: rawStatus ?? "missing",
        to: to.rawValue
      )
    }
    try db.execute(
      sql: """
        UPDATE runTargets SET status = ?, failureSummary = ?, artifactSet = ?, updatedAt = ?
        WHERE runID = ? AND targetID = ?
        """,
      arguments: [
        to.rawValue,
        failureSummary,
        try encodeArtifacts(artifacts),
        date.timeIntervalSinceReferenceDate,
        runID.rawValue,
        targetID,
      ]
    )
  }

  fileprivate static func interruptRunningTargets(
    _ db: Database,
    runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try db.execute(
      sql: """
        UPDATE runTargets
        SET status = ?, failureSummary = COALESCE(failureSummary, 'cancelled'), updatedAt = ?
        WHERE runID = ? AND status = ?
        """,
      arguments: [
        PrivateHeaderGeneration.RunTargetStatus.interrupted.rawValue,
        date.timeIntervalSinceReferenceDate,
        runID.rawValue,
        PrivateHeaderGeneration.RunTargetStatus.running.rawValue,
      ]
    )
  }

  fileprivate static func interruptDanglingRuns(_ db: Database, at date: Date) throws {
    let ids = try String.fetchAll(
      db,
      sql: """
        SELECT id FROM runs
        WHERE status = ?
          AND id NOT IN (
            SELECT runID FROM publicationIntents WHERE state IN (?, ?)
          )
        """,
      arguments: [
        PrivateHeaderGeneration.RunStatus.running.rawValue,
        PrivateHeaderGeneration.PublicationState.prepared.rawValue,
        PrivateHeaderGeneration.PublicationState.pointerPublished.rawValue,
      ]
    )
    for rawID in ids {
      let id = try PrivateHeaderGeneration.RunID(rawID)
      try interruptRunningTargets(db, runID: id, at: date)
      try db.execute(
        sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
        arguments: [
          PrivateHeaderGeneration.RunStatus.interrupted.rawValue,
          date.timeIntervalSinceReferenceDate,
          rawID,
        ]
      )
    }
  }

  fileprivate static func abortIntent(
    _ db: Database,
    intent: PrivateHeaderGeneration.PublicationIntent,
    terminalReason: PrivateHeaderGeneration.RecoveryTerminalReason,
    at date: Date
  ) throws {
    try db.execute(
      sql: "UPDATE publicationIntents SET state = ?, completedAt = ? WHERE generationID = ?",
      arguments: [
        PrivateHeaderGeneration.PublicationState.aborted.rawValue,
        date.timeIntervalSinceReferenceDate,
        intent.generationID.rawValue,
      ]
    )
    if try runStatus(db, id: intent.runID) == .running {
      switch terminalReason {
      case .interrupted:
        try interruptRunningTargets(db, runID: intent.runID, at: date)
        try db.execute(
          sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
          arguments: [
            PrivateHeaderGeneration.RunStatus.interrupted.rawValue,
            date.timeIntervalSinceReferenceDate,
            intent.runID.rawValue,
          ]
        )
      case .failed(let message):
        try db.execute(
          sql: """
            UPDATE runTargets
            SET status = ?, failureSummary = COALESCE(failureSummary, ?), updatedAt = ?
            WHERE runID = ?
              AND (
                status = ?
                OR (
                  status = ?
                  AND targetID NOT IN (
                    SELECT targetID FROM targets WHERE lastSuccessfulRunID = ?
                  )
                )
              )
            """,
          arguments: [
            PrivateHeaderGeneration.RunTargetStatus.failed.rawValue,
            message,
            date.timeIntervalSinceReferenceDate,
            intent.runID.rawValue,
            PrivateHeaderGeneration.RunTargetStatus.running.rawValue,
            PrivateHeaderGeneration.RunTargetStatus.completed.rawValue,
            intent.runID.rawValue,
          ]
        )
        try db.execute(
          sql: """
            UPDATE runs
            SET status = ?, endedAt = ?, terminalStatusOverride = NULL
            WHERE id = ?
            """,
          arguments: [
            PrivateHeaderGeneration.RunStatus.failed.rawValue,
            date.timeIntervalSinceReferenceDate,
            intent.runID.rawValue,
          ]
        )
      }
    }
  }

  fileprivate static func finalizePublication(
    _ db: Database,
    intent: PrivateHeaderGeneration.PublicationIntent,
    at date: Date,
    shouldInterrupt: @Sendable () -> Bool,
    faultInjector: FaultInjector
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    guard intent.state == .pointerPublished else {
      throw PrivateHeaderGeneration.StateError.invalidTransition(
        entity: "publication",
        from: intent.state.rawValue,
        to: PrivateHeaderGeneration.PublicationState.committed.rawValue
      )
    }
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT * FROM runTargets WHERE runID = ? AND status = ? ORDER BY targetID",
      arguments: [
        intent.runID.rawValue, PrivateHeaderGeneration.RunTargetStatus.completed.rawValue,
      ]
    )
    for row in rows {
      let targetID: String = row["targetID"]
      let artifacts: String = row["artifactSet"]
      let updatedAt: Double = row["updatedAt"]
      try db.execute(
        sql: """
          INSERT INTO targets(targetID, lastSuccessfulRunID, status, artifactSet, updatedAt)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(targetID) DO UPDATE SET
              lastSuccessfulRunID = excluded.lastSuccessfulRunID,
              status = excluded.status,
              artifactSet = excluded.artifactSet,
              updatedAt = excluded.updatedAt
          """,
        arguments: [
          targetID,
          intent.runID.rawValue,
          PrivateHeaderGeneration.RunTargetStatus.completed.rawValue,
          artifacts,
          updatedAt,
        ]
      )
    }
    try interruptRunningTargets(db, runID: intent.runID, at: date)
    let status = try finalRunStatus(db, runID: intent.runID)
    try db.execute(
      sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
      arguments: [status.rawValue, date.timeIntervalSinceReferenceDate, intent.runID.rawValue]
    )
    try faultInjector(.afterSemanticFinalize)
    if shouldInterrupt() {
      try applyInterruptionOverride(db, runID: intent.runID)
      try db.execute(
        sql: "UPDATE runs SET status = ? WHERE id = ?",
        arguments: [
          PrivateHeaderGeneration.RunStatus.interrupted.rawValue,
          intent.runID.rawValue,
        ]
      )
    }
    try db.execute(
      sql: "UPDATE publicationIntents SET state = ?, completedAt = ? WHERE generationID = ?",
      arguments: [
        PrivateHeaderGeneration.PublicationState.committed.rawValue,
        date.timeIntervalSinceReferenceDate,
        intent.generationID.rawValue,
      ]
    )
    return try fetchRun(db, id: intent.runID)
  }

  fileprivate static func applyInterruptionOverride(
    _ db: Database,
    runID: PrivateHeaderGeneration.RunID
  ) throws {
    try db.execute(
      sql: "UPDATE runs SET terminalStatusOverride = ? WHERE id = ?",
      arguments: [PrivateHeaderGeneration.RunStatus.interrupted.rawValue, runID.rawValue]
    )
  }

  fileprivate static func finalRunStatus(
    _ db: Database,
    runID: PrivateHeaderGeneration.RunID
  ) throws -> PrivateHeaderGeneration.RunStatus {
    if let rawOverride = try String.fetchOne(
      db,
      sql: "SELECT terminalStatusOverride FROM runs WHERE id = ?",
      arguments: [runID.rawValue]
    ) {
      guard let override = PrivateHeaderGeneration.RunStatus(rawValue: rawOverride),
        override != .running
      else {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "invalid terminal run override \(rawOverride)")
      }
      return override
    }
    let rawStatuses = try String.fetchAll(
      db,
      sql: "SELECT status FROM runTargets WHERE runID = ?",
      arguments: [runID.rawValue]
    )
    let statuses = try rawStatuses.map { rawStatus in
      guard let status = PrivateHeaderGeneration.RunTargetStatus(rawValue: rawStatus) else {
        throw PrivateHeaderGeneration.StateError.corruptPublication(
          "unknown target status \(rawStatus)"
        )
      }
      return status
    }
    let attempted = statuses.filter { $0 != .skipped && $0 != .pending }
    if attempted.contains(.interrupted) { return .interrupted }
    if attempted.allSatisfy({ $0 == .completed }) { return .completed }
    if attempted.contains(.completed) { return .partial }
    if attempted.contains(.partial) { return .partial }
    return .failed
  }

  fileprivate static func fetchRun(
    _ db: Database,
    id: PrivateHeaderGeneration.RunID
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [id.rawValue])
    else {
      throw PrivateHeaderGeneration.StateError.missingRun(id)
    }
    let rawStatus: String = row["status"]
    guard let status = PrivateHeaderGeneration.RunStatus(rawValue: rawStatus) else {
      throw PrivateHeaderGeneration.StateError.corruptPublication("unknown run status \(rawStatus)")
    }
    let targetRows = try Row.fetchAll(
      db,
      sql: "SELECT * FROM runTargets WHERE runID = ? ORDER BY targetID",
      arguments: [id.rawValue]
    )
    let targetIDsJSON: String = row["targetIDs"]
    let endedAtValue: Double? = row["endedAt"]
    return PrivateHeaderGeneration.RunSnapshot(
      id: id,
      sourceIdentity: row["sourceIdentity"],
      planFingerprint: row["planFingerprint"],
      targetIDs: try decodeStrings(targetIDsJSON),
      startedAt: Date(timeIntervalSinceReferenceDate: row["startedAt"]),
      endedAt: endedAtValue.map(Date.init(timeIntervalSinceReferenceDate:)),
      status: status,
      targets: try targetRows.map(targetAttemptSnapshot)
    )
  }

  fileprivate static func targetAttemptSnapshot(_ row: Row) throws
    -> PrivateHeaderGeneration.TargetAttemptSnapshot
  {
    let rawStatus: String = row["status"]
    guard let status = PrivateHeaderGeneration.RunTargetStatus(rawValue: rawStatus) else {
      throw PrivateHeaderGeneration.StateError.corruptPublication(
        "unknown target status \(rawStatus)")
    }
    let artifactJSON: String = row["artifactSet"]
    return PrivateHeaderGeneration.TargetAttemptSnapshot(
      targetID: row["targetID"],
      displayName: row["displayName"],
      kind: row["kind"],
      status: status,
      artifacts: try decodeArtifacts(artifactJSON),
      failureSummary: row["failureSummary"]
    )
  }

  fileprivate static func targetSnapshot(_ row: Row) throws
    -> PrivateHeaderGeneration.TargetSnapshot
  {
    let rawStatus: String = row["status"]
    guard let status = PrivateHeaderGeneration.RunTargetStatus(rawValue: rawStatus) else {
      throw PrivateHeaderGeneration.StateError.corruptPublication(
        "unknown target status \(rawStatus)")
    }
    let artifactJSON: String = row["artifactSet"]
    return PrivateHeaderGeneration.TargetSnapshot(
      targetID: row["targetID"],
      lastSuccessfulRunID: try PrivateHeaderGeneration.RunID(row["lastSuccessfulRunID"]),
      status: status,
      artifacts: try decodeArtifacts(artifactJSON),
      updatedAt: Date(timeIntervalSinceReferenceDate: row["updatedAt"])
    )
  }

  fileprivate static func fetchLatestPublicationIntent(_ db: Database) throws
    -> PrivateHeaderGeneration.PublicationIntent?
  {
    guard
      let id = try String.fetchOne(
        db,
        sql: """
          SELECT publicationIntents.generationID
          FROM publicationIntents
          JOIN publicationOrdering
              ON publicationOrdering.generationID = publicationIntents.generationID
          ORDER BY publicationOrdering.sequence DESC
          LIMIT 1
          """
      )
    else {
      return nil
    }
    return try fetchPublicationIntent(db, generationID: PrivateHeaderGeneration.GenerationID(id))
  }

  fileprivate static func fetchPublicationIntentIfPresent(
    _ db: Database,
    generationID: PrivateHeaderGeneration.GenerationID
  ) throws -> PrivateHeaderGeneration.PublicationIntent? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT * FROM publicationIntents WHERE generationID = ?",
        arguments: [generationID.rawValue]
      )
    else {
      return nil
    }
    return try publicationIntent(row)
  }

  fileprivate static func fetchPublicationIntent(
    _ db: Database,
    generationID: PrivateHeaderGeneration.GenerationID
  ) throws -> PrivateHeaderGeneration.PublicationIntent {
    guard let intent = try fetchPublicationIntentIfPresent(db, generationID: generationID) else {
      throw PrivateHeaderGeneration.StateError.missingPublicationIntent(generationID)
    }
    return intent
  }

  fileprivate static func publicationIntent(_ row: Row) throws
    -> PrivateHeaderGeneration.PublicationIntent
  {
    let rawState: String = row["state"]
    guard let state = PrivateHeaderGeneration.PublicationState(rawValue: rawState) else {
      throw PrivateHeaderGeneration.StateError.corruptPublication(
        "unknown publication state \(rawState)")
    }
    let previous: String? = row["previousGenerationID"]
    let completedAt: Double? = row["completedAt"]
    return PrivateHeaderGeneration.PublicationIntent(
      generationID: try PrivateHeaderGeneration.GenerationID(row["generationID"]),
      runID: try PrivateHeaderGeneration.RunID(row["runID"]),
      previousGenerationID: try previous.map { try PrivateHeaderGeneration.GenerationID($0) },
      state: state,
      planFingerprint: row["planFingerprint"],
      artifactChecksum: row["artifactChecksum"],
      createdAt: Date(timeIntervalSinceReferenceDate: row["createdAt"]),
      completedAt: completedAt.map(Date.init(timeIntervalSinceReferenceDate:))
    )
  }

  fileprivate static func encodeStrings(_ values: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  fileprivate static func decodeStrings(_ value: String) throws -> [String] {
    try JSONDecoder().decode([String].self, from: Data(value.utf8))
  }

  fileprivate static func encodeArtifacts(_ values: [PrivateHeaderGeneration.ArtifactPath]) throws
    -> String
  {
    try encodeStrings(values.map(\.rawValue).sorted())
  }

  fileprivate static func decodeArtifacts(_ value: String) throws -> [PrivateHeaderGeneration
    .ArtifactPath]
  {
    try decodeStrings(value).map { try PrivateHeaderGeneration.ArtifactPath($0) }
  }
}
