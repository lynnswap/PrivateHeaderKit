import Foundation
import GRDB

/// The per-source SQLite record of generation runs, target attempts, and published targets.
package actor GenerationStore {
  private let databaseQueue: DatabaseQueue

  package init(databaseURL: URL) throws {
    try FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.label = "PrivateHeaderKit.GenerationStore"
    let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
    if try queue.read(Self.migrator.hasBeenSuperseded) {
      let unknownIdentifiers = try queue.read { db in
        try Self.migrator.appliedIdentifiers(db).subtracting(Self.migrator.migrations)
      }
      throw PrivateHeaderGeneration.StateError.unsupportedMigrations(unknownIdentifiers.sorted())
    }
    try Self.migrator.migrate(queue)
    databaseQueue = queue
  }

  // MARK: Runs

  /// Ends runs that a terminated process left in the running state.
  package func interruptUnfinishedRuns(at date: Date) throws {
    try databaseQueue.write { db in
      let runIDs = try String.fetchAll(
        db,
        sql: "SELECT id FROM runs WHERE status = ?",
        arguments: [PrivateHeaderGeneration.RunStatus.running.rawValue]
      )
      for runID in runIDs {
        try Self.interruptRunningTargets(db, runID: runID, at: date)
        try Self.endRun(db, runID: runID, status: .interrupted, at: date)
      }
    }
  }

  package func beginRun(
    id: PrivateHeaderGeneration.RunID,
    plan: PrivateHeaderGeneration.RunPlan,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO runs(
              id, sourceIdentity, planFingerprint, targetIDs, startedAt, endedAt, status, isResumable
          ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
          """,
        arguments: [
          id.rawValue,
          plan.sourceIdentity,
          plan.fingerprint,
          try Self.encode(plan.targetIDs),
          date.timeIntervalSinceReferenceDate,
          PrivateHeaderGeneration.RunStatus.running.rawValue,
          plan.isResumable,
        ]
      )
      try db.execute(sql: "INSERT INTO runOrdering(runID) VALUES (?)", arguments: [id.rawValue])
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
    }
  }

  /// Ends a run with the status its target attempts add up to, or as interrupted.
  package func finishRun(
    _ runID: PrivateHeaderGeneration.RunID,
    interrupted: Bool,
    at date: Date
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
      try Self.interruptRunningTargets(db, runID: runID.rawValue, at: date)
      let status =
        interrupted
        ? PrivateHeaderGeneration.RunStatus.interrupted
        : Self.runStatus(forTargetStatuses: try Self.fetchRun(db, id: runID).targets.map(\.status))
      try Self.endRun(db, runID: runID.rawValue, status: status, at: date)
      return try Self.fetchRun(db, id: runID)
    }
  }

  /// Ends a run that stopped on an error outside any single target.
  package func failRun(
    _ runID: PrivateHeaderGeneration.RunID,
    message: String,
    at date: Date
  ) throws -> PrivateHeaderGeneration.RunSnapshot {
    try databaseQueue.write { db in
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
      try Self.endRun(db, runID: runID.rawValue, status: .failed, at: date)
      return try Self.fetchRun(db, id: runID)
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

  package func recordRunLog(
    runID: PrivateHeaderGeneration.RunID,
    warning: PrivateHeaderGeneration.GenerationWarning
  ) throws {
    try databaseQueue.write { db in
      try Self.insertRunLog(db, runID: runID, warning: warning)
    }
  }

  // MARK: Target attempts

  package func beginTargetAttempt(
    targetID: String,
    displayName: String,
    kind: String,
    in runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
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

  package func markSkipped(
    targetID: String,
    in runID: PrivateHeaderGeneration.RunID,
    at date: Date
  ) throws {
    try databaseQueue.write { db in
      try db.execute(
        sql: "UPDATE runTargets SET status = ?, updatedAt = ? WHERE runID = ? AND targetID = ?",
        arguments: [
          PrivateHeaderGeneration.RunTargetStatus.skipped.rawValue,
          date.timeIntervalSinceReferenceDate,
          runID.rawValue,
          targetID,
        ]
      )
    }
  }

  /// Withdraws the target's published record and records the files the running attempt is
  /// about to publish. A publication that stops partway then leaves the target unpublished,
  /// and a later attempt can remove the files it left behind.
  package func beginPublishing(
    _ artifacts: [PrivateHeaderGeneration.ArtifactPath],
    targetID: String,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    try databaseQueue.write { db in
      try db.execute(
        sql: "UPDATE runTargets SET artifactSet = ? WHERE runID = ? AND targetID = ?",
        arguments: [try Self.encode(artifacts), runID.rawValue, targetID]
      )
      try db.execute(sql: "DELETE FROM targets WHERE targetID = ?", arguments: [targetID])
    }
  }

  /// Records an attempt that ended without publishing.
  package func recordTargetAttempt(
    _ result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    try databaseQueue.write { db in
      try Self.updateRunTarget(db, result: result, in: runID)
    }
  }

  /// Records a completed attempt whose files are now the target's published output.
  package func recordPublishedTarget(
    _ result: PrivateHeaderGeneration.TargetAttemptResult,
    warnings: [PrivateHeaderGeneration.GenerationWarning] = [],
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
    try databaseQueue.write { db in
      try Self.updateRunTarget(db, result: result, in: runID)
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
          try Self.encode(result.artifacts),
          result.completedAt.timeIntervalSinceReferenceDate,
        ]
      )
      for warning in warnings {
        try Self.insertRunLog(db, runID: runID, warning: warning)
      }
    }
  }

  // MARK: Published targets

  package func publishedArtifactsByTarget()
    throws -> [String: [PrivateHeaderGeneration.ArtifactPath]]
  {
    try databaseQueue.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT targetID, artifactSet FROM targets")
          .map { row in (row["targetID"] as String, try Self.decodeArtifacts(row["artifactSet"])) }
      )
    }
  }

  package func publishedArtifacts(
    targetID: String
  ) throws -> [PrivateHeaderGeneration.ArtifactPath] {
    try databaseQueue.read { db in
      let artifactSet = try String.fetchOne(
        db,
        sql: "SELECT artifactSet FROM targets WHERE targetID = ?",
        arguments: [targetID]
      )
      return try artifactSet.map(Self.decodeArtifacts) ?? []
    }
  }

  /// The files recorded by attempts made since the target's current publication, or by every
  /// attempt when the target is unpublished. An attempt that stopped while publishing may
  /// have left some of them behind.
  package func unpublishedAttemptArtifacts(
    targetID: String
  ) throws -> Set<PrivateHeaderGeneration.ArtifactPath> {
    try databaseQueue.read { db in
      let artifactSets = try String.fetchAll(
        db,
        sql: """
          SELECT runTargets.artifactSet
          FROM runTargets JOIN runOrdering ON runOrdering.runID = runTargets.runID
          WHERE runTargets.targetID = :targetID
            AND runOrdering.sequence > COALESCE(
              (
                SELECT runOrdering.sequence
                FROM targets JOIN runOrdering ON runOrdering.runID = targets.lastSuccessfulRunID
                WHERE targets.targetID = :targetID
              ),
              0
            )
          """,
        arguments: ["targetID": targetID]
      )
      return Set(try artifactSets.flatMap(Self.decodeArtifacts))
    }
  }

  /// The latest all-target run together with where each target was last published.
  ///
  /// - Parameter availableTargetIDs: Published targets whose files are all still present.
  package func allTargetCheckpoint(
    availableTargetIDs: Set<String>
  ) throws -> PrivateHeaderGeneration.AllTargetCheckpoint? {
    try databaseQueue.read { db in
      guard
        let latest = try Row.fetchOne(
          db,
          sql: """
            SELECT runs.id, runOrdering.sequence
            FROM runs JOIN runOrdering ON runOrdering.runID = runs.id
            WHERE runs.isResumable = 1
            ORDER BY runOrdering.sequence DESC
            LIMIT 1
            """
        )
      else { return nil }
      let run = try Self.fetchRun(db, id: PrivateHeaderGeneration.RunID(latest["id"]))
      let publications = try Row.fetchAll(
        db,
        sql: """
          SELECT targets.targetID, runs.planFingerprint, runOrdering.sequence
          FROM targets
          JOIN runs ON runs.id = targets.lastSuccessfulRunID
          JOIN runOrdering ON runOrdering.runID = runs.id
          """
      ).map { row in
        let targetID: String = row["targetID"]
        return (
          targetID,
          PrivateHeaderGeneration.AllTargetCheckpoint.Publication(
            fingerprint: row["planFingerprint"],
            sequence: row["sequence"],
            isAvailable: availableTargetIDs.contains(targetID)
          )
        )
      }
      return PrivateHeaderGeneration.AllTargetCheckpoint(
        run: run,
        sequence: latest["sequence"],
        publications: Dictionary(uniqueKeysWithValues: publications)
      )
    }
  }
}

// MARK: - Rows

extension GenerationStore {
  fileprivate static func updateRunTarget(
    _ db: Database,
    result: PrivateHeaderGeneration.TargetAttemptResult,
    in runID: PrivateHeaderGeneration.RunID
  ) throws {
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
        try encode(result.artifacts),
        result.completedAt.timeIntervalSinceReferenceDate,
        runID.rawValue,
        result.targetID,
      ]
    )
  }

  fileprivate static func insertRunLog(
    _ db: Database,
    runID: PrivateHeaderGeneration.RunID,
    warning: PrivateHeaderGeneration.GenerationWarning
  ) throws {
    try db.execute(
      sql: "INSERT INTO runLogs(runID, kind, relativePath, message) VALUES (?, ?, ?, ?)",
      arguments: [runID.rawValue, warning.kind, warning.relativePath, warning.message]
    )
  }

  fileprivate static func interruptRunningTargets(
    _ db: Database,
    runID: String,
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
        runID,
        PrivateHeaderGeneration.RunTargetStatus.running.rawValue,
      ]
    )
  }

  fileprivate static func endRun(
    _ db: Database,
    runID: String,
    status: PrivateHeaderGeneration.RunStatus,
    at date: Date
  ) throws {
    try db.execute(
      sql: "UPDATE runs SET status = ?, endedAt = ? WHERE id = ?",
      arguments: [status.rawValue, date.timeIntervalSinceReferenceDate, runID]
    )
  }

  fileprivate static func runStatus(
    forTargetStatuses statuses: [PrivateHeaderGeneration.RunTargetStatus]
  ) -> PrivateHeaderGeneration.RunStatus {
    let attempted = statuses.filter { $0 != .skipped && $0 != .pending }
    if attempted.contains(.interrupted) { return .interrupted }
    if attempted.allSatisfy({ $0 == .completed }) { return .completed }
    if attempted.contains(.completed) || attempted.contains(.partial) { return .partial }
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
    let targets = try Row.fetchAll(
      db,
      sql: "SELECT * FROM runTargets WHERE runID = ? ORDER BY targetID",
      arguments: [id.rawValue]
    ).map { targetRow in
      PrivateHeaderGeneration.TargetAttemptSnapshot(
        targetID: targetRow["targetID"],
        displayName: targetRow["displayName"],
        kind: targetRow["kind"],
        status: try decodeStatus(targetRow["status"]),
        artifacts: try decodeArtifacts(targetRow["artifactSet"]),
        failureSummary: targetRow["failureSummary"]
      )
    }
    let endedAt: Double? = row["endedAt"]
    return PrivateHeaderGeneration.RunSnapshot(
      id: id,
      sourceIdentity: row["sourceIdentity"],
      planFingerprint: row["planFingerprint"],
      targetIDs: try JSONDecoder().decode([String].self, from: Data((row["targetIDs"] as String).utf8)),
      startedAt: Date(timeIntervalSinceReferenceDate: row["startedAt"]),
      endedAt: endedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
      status: try decodeStatus(row["status"]),
      targets: targets
    )
  }

  fileprivate static func decodeStatus<Status: RawRepresentable<String>>(
    _ rawValue: String
  ) throws -> Status {
    guard let status = Status(rawValue: rawValue) else {
      throw DatabaseError(message: "unknown \(Status.self) value \(rawValue)")
    }
    return status
  }

  fileprivate static func encode(_ values: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
  }

  fileprivate static func encode(
    _ artifacts: [PrivateHeaderGeneration.ArtifactPath]
  ) throws -> String {
    try encode(artifacts.map(\.rawValue).sorted())
  }

  fileprivate static func decodeArtifacts(
    _ value: String
  ) throws -> [PrivateHeaderGeneration.ArtifactPath] {
    try JSONDecoder().decode([String].self, from: Data(value.utf8)).map {
      try PrivateHeaderGeneration.ArtifactPath($0)
    }
  }
}

// MARK: - Schema

extension GenerationStore {
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
    migrator.registerMigration("v4-published-artifact-digests") { db in
      try db.execute(
        sql: """
          ALTER TABLE targets
          ADD COLUMN artifactDigests TEXT NOT NULL DEFAULT '{}';
          """)
    }
    migrator.registerMigration("v5-all-target-resume") { db in
      // Older runs did not record their selection scope. Keep their artifacts without
      // guessing whether an individual selection was an all-target run.
      try db.execute(sql: "ALTER TABLE runs ADD COLUMN isResumable BOOLEAN NOT NULL DEFAULT 0")
    }
    migrator.registerMigration("v6-direct-target-publication") { db in
      // Targets are published straight into the header directory, so the generation
      // snapshots and their two-phase publication records have no reader left.
      try db.execute(
        sql: """
          DROP TABLE publicationOrdering;
          DROP TABLE publicationIntents;
          DROP TABLE metadata;
          ALTER TABLE targets DROP COLUMN artifactDigests;
          ALTER TABLE runs DROP COLUMN terminalStatusOverride;
          """)
    }
    return migrator
  }
}
