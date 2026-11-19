import Foundation
import GRDB
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationStoreTests {
  @Test func migratesDatabaseWithOpenPublicationToDirectTargetPublication() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("generation.sqlite")
    let queue = try DatabaseQueue(path: databaseURL.path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-generation-state") { db in
      try createVersionOneSchema(db)
      try db.execute(
        sql: """
          INSERT INTO runs VALUES ('run-old', 'source', 'fingerprint', '["framework:Foo"]', 1, NULL, 'running', NULL);
          INSERT INTO runTargets VALUES
              ('run-old', 'framework:Foo', 'Foo', 'framework', 'running', NULL, '[]', 1);
          INSERT INTO targets VALUES
              ('framework:Foo', 'run-old', 'completed', '["Frameworks/Foo/Headers/Foo.h"]', 1);
          INSERT INTO publicationIntents VALUES
              ('generation-old', 'run-old', NULL, 'prepared', 'fingerprint', 'checksum', 1, NULL);
          """)
    }
    try migrator.migrate(queue)

    let store = try GenerationStore(databaseURL: databaseURL)
    try await store.interruptUnfinishedRuns(at: Date(timeIntervalSinceReferenceDate: 2))

    let tables = try await queue.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(!tables.contains("publicationIntents"))
    #expect(!tables.contains("publicationOrdering"))
    #expect(
      try await store.publishedArtifacts(targetID: "framework:Foo")
        == [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Headers/Foo.h")]
    )
    let run = try #require(try await store.latestRunSnapshot())
    #expect(run.status == .interrupted)
    #expect(run.targets.map(\.status) == [.interrupted])
  }

  @Test func unknownFutureMigrationFailsFastBeforeMigration() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("generation.sqlite")
    _ = try GenerationStore(databaseURL: databaseURL)
    let queue = try DatabaseQueue(path: databaseURL.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
        arguments: ["v999-future"]
      )
    }

    do {
      _ = try GenerationStore(databaseURL: databaseURL)
      Issue.record("future migration was unexpectedly accepted")
    } catch let error as PrivateHeaderGeneration.StateError {
      #expect(error == .unsupportedMigrations(["v999-future"]))
    }
  }

  @Test func publishedTargetIsRecordedBeforeItsRunEnds() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = try await fixture.beginRun("run-incremental", targetIDs: ["framework:Foo"])
    let completed = fixture.completedTarget("framework:Foo")

    try await fixture.store.beginPublishing(
      completed.artifacts, targetID: "framework:Foo", in: runID
    )
    #expect(
      try await fixture.store.unpublishedAttemptArtifacts(targetID: "framework:Foo")
        == Set(completed.artifacts)
    )
    #expect(try await fixture.store.publishedArtifacts(targetID: "framework:Foo").isEmpty)

    let warning = PrivateHeaderGeneration.GenerationWarning(
      kind: "objc-metadata-warning", relativePath: "Frameworks/Foo", message: "Foo: degraded"
    )
    try await fixture.store.recordPublishedTarget(completed, warnings: [warning], in: runID)

    let run = try #require(try await fixture.store.latestRunSnapshot())
    #expect(run.status == .running)
    #expect(run.targets.map(\.status) == [.completed])
    #expect(
      try await fixture.store.publishedArtifactsByTarget() == ["framework:Foo": completed.artifacts]
    )
    #expect(try await fixture.store.unpublishedAttemptArtifacts(targetID: "framework:Foo").isEmpty)
    #expect(try await fixture.loggedMessages() == ["Foo: degraded"])
  }

  @Test func publicationThatDidNotFinishLeavesTheTargetUnpublished() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let firstRunID = try await fixture.beginRun("run-first", targetIDs: ["framework:Foo"])
    let published = fixture.completedTarget("framework:Foo")
    try await fixture.store.recordPublishedTarget(published, in: firstRunID)
    _ = try await fixture.store.finishRun(firstRunID, interrupted: false, at: fixture.date)
    let secondRunID = try await fixture.beginRun("run-second", targetIDs: ["framework:Foo"])
    let incoming = PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/New.h")

    try await fixture.store.beginPublishing([incoming], targetID: "framework:Foo", in: secondRunID)

    #expect(try await fixture.store.publishedArtifacts(targetID: "framework:Foo").isEmpty)
    #expect(
      try await fixture.store.unpublishedAttemptArtifacts(targetID: "framework:Foo")
        == Set(published.artifacts + [incoming])
    )
    let checkpoint = try #require(
      try await fixture.store.allTargetCheckpoint(availableTargetIDs: [])
    )
    #expect(checkpoint.hasUnfinishedWork)
  }

  @Test func checkpointReportsPublishedAndNewTargets() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = try await fixture.beginRun("run-publication", targetIDs: ["framework:Foo"])
    try await fixture.store.recordPublishedTarget(
      fixture.completedTarget("framework:Foo"), in: runID
    )
    _ = try await fixture.store.finishRun(runID, interrupted: false, at: fixture.date)

    let checkpoint = try #require(
      try await fixture.store.allTargetCheckpoint(availableTargetIDs: ["framework:Foo"])
    )
    #expect(!checkpoint.hasUnfinishedWork)
    let summary = checkpoint.resumeSummary(
      selectedTargetIDs: ["framework:Foo", "framework:Bar"], at: fixture.date
    )
    #expect(summary.targets.map(\.status) == [.completed, .pending])

    let missingArtifacts = try #require(
      try await fixture.store.allTargetCheckpoint(availableTargetIDs: [])
    )
    #expect(!missingArtifacts.hasUnfinishedWork)
    #expect(
      missingArtifacts.resumeSummary(selectedTargetIDs: ["framework:Foo"], at: fixture.date)
        .targets.map(\.status) == [.pending]
    )
  }

  @Test func targetPublishedOnlyByAnEarlierRunIsUnfinishedInTheCheckpoint() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let firstRunID = try await fixture.beginRun("run-first", targetIDs: ["framework:Foo"])
    try await fixture.store.recordPublishedTarget(
      fixture.completedTarget("framework:Foo"), in: firstRunID
    )
    _ = try await fixture.store.finishRun(firstRunID, interrupted: false, at: fixture.date)

    let secondRunID = try await fixture.beginRun("run-second", targetIDs: ["framework:Foo"])
    _ = try await fixture.store.finishRun(secondRunID, interrupted: true, at: fixture.date)

    let checkpoint = try #require(
      try await fixture.store.allTargetCheckpoint(availableTargetIDs: ["framework:Foo"])
    )
    #expect(checkpoint.hasUnfinishedWork)
    #expect(
      checkpoint.resumeSummary(selectedTargetIDs: ["framework:Foo"], at: fixture.date).targets
        == [.init(targetID: "framework:Foo", status: .interrupted)]
    )
  }

  @Test(arguments: [
    ([PrivateHeaderGeneration.RunTargetStatus.completed, .completed], PrivateHeaderGeneration.RunStatus.completed),
    ([.completed, .failed], .partial),
    ([.partial, .failed], .partial),
    ([.failed, .failed], .failed),
  ])
  func finishedRunStatusFollowsItsTargetAttempts(
    targetStatuses: [PrivateHeaderGeneration.RunTargetStatus],
    expected: PrivateHeaderGeneration.RunStatus
  ) async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let targetIDs = targetStatuses.indices.map { "framework:Target\($0)" }
    let runID = try await fixture.beginRun("run-status", targetIDs: targetIDs + ["framework:Skipped"])
    for (targetID, status) in zip(targetIDs, targetStatuses) {
      if status == .completed {
        try await fixture.store.recordPublishedTarget(fixture.completedTarget(targetID), in: runID)
      } else {
        try await fixture.store.recordTargetAttempt(
          .init(
            targetID: targetID, displayName: targetID, kind: "framework", status: status,
            failureSummary: "failed", completedAt: fixture.date
          ),
          in: runID
        )
      }
    }
    try await fixture.store.markSkipped(targetID: "framework:Skipped", in: runID, at: fixture.date)

    #expect(
      try await fixture.store.finishRun(runID, interrupted: false, at: fixture.date).status
        == expected
    )
  }

  @Test func interruptedRunEndsItsRunningTargetAsInterrupted() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = try await fixture.beginRun("run-interrupt", targetIDs: ["framework:Foo"])

    let run = try await fixture.store.finishRun(runID, interrupted: true, at: fixture.date)

    #expect(run.status == .interrupted)
    #expect(run.targets.map(\.status) == [.interrupted])
  }

  @Test func failedRunKeepsPublishedTargetsAndFailsTheRunningOne() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = try await fixture.beginRun(
      "run-failure", targetIDs: ["framework:Bar", "framework:Foo"]
    )
    try await fixture.store.recordPublishedTarget(
      fixture.completedTarget("framework:Bar"), in: runID
    )

    let run = try await fixture.store.failRun(runID, message: "helper mismatch", at: fixture.date)

    #expect(run.status == .failed)
    #expect(run.targets.map(\.status) == [.completed, .failed])
    #expect(run.targets.map(\.failureSummary) == [nil, "helper mismatch"])
  }

  @Test func latestRunUsesInsertionOrderInsteadOfWallClock() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    _ = try await fixture.beginRun(
      "run-inserted-first", targetIDs: ["framework:Foo"],
      at: Date(timeIntervalSinceReferenceDate: 500)
    )
    try await fixture.store.interruptUnfinishedRuns(at: fixture.date)
    let secondRunID = try await fixture.beginRun(
      "run-inserted-second", targetIDs: ["framework:Foo"],
      at: Date(timeIntervalSinceReferenceDate: 100)
    )

    #expect(try await fixture.store.latestRunSnapshot()?.id == secondRunID)
  }
}

private final class StoreFixture: Sendable {
  let root: URL
  let databaseURL: URL
  let store: GenerationStore
  let date = Date(timeIntervalSinceReferenceDate: 100)

  init() throws {
    root = try temporaryDirectory()
    databaseURL = root.appendingPathComponent("generation.sqlite")
    store = try GenerationStore(databaseURL: databaseURL)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  /// Begins an all-target run whose targets have all started their attempts.
  func beginRun(
    _ rawRunID: String,
    targetIDs: [String],
    at startDate: Date? = nil
  ) async throws -> PrivateHeaderGeneration.RunID {
    let runID = PrivateHeaderGeneration.RunID(rawValue: rawRunID)
    try await store.beginRun(
      id: runID,
      plan: .init(
        sourceIdentity: "iOS|27.0|24A",
        fingerprint: "fingerprint",
        targetIDs: targetIDs,
        isResumable: true
      ),
      at: startDate ?? date
    )
    for targetID in targetIDs {
      try await store.beginTargetAttempt(
        targetID: targetID, displayName: targetID, kind: "framework", in: runID,
        at: startDate ?? date
      )
    }
    return runID
  }

  func completedTarget(_ targetID: String) -> PrivateHeaderGeneration.TargetAttemptResult {
    .init(
      targetID: targetID,
      displayName: targetID,
      kind: "framework",
      status: .completed,
      artifacts: [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Foo.h")],
      completedAt: date
    )
  }

  func loggedMessages() async throws -> [String] {
    try await DatabaseQueue(path: databaseURL.path).read { db in
      try String.fetchAll(db, sql: "SELECT message FROM runLogs ORDER BY id")
    }
  }
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "PrivateHeaderKitCoreTests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}

private func createVersionOneSchema(_ db: Database) throws {
  try db.execute(
    sql: """
      CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
      CREATE TABLE runs (
          id TEXT PRIMARY KEY NOT NULL, sourceIdentity TEXT NOT NULL,
          planFingerprint TEXT NOT NULL, targetIDs TEXT NOT NULL,
          startedAt DOUBLE NOT NULL, endedAt DOUBLE, status TEXT NOT NULL,
          terminalStatusOverride TEXT
      );
      CREATE TABLE runTargets (
          runID TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
          targetID TEXT NOT NULL, displayName TEXT NOT NULL, kind TEXT NOT NULL,
          status TEXT NOT NULL, failureSummary TEXT, artifactSet TEXT NOT NULL,
          updatedAt DOUBLE NOT NULL, PRIMARY KEY (runID, targetID)
      );
      CREATE TABLE targets (
          targetID TEXT PRIMARY KEY NOT NULL,
          lastSuccessfulRunID TEXT NOT NULL REFERENCES runs(id),
          status TEXT NOT NULL, artifactSet TEXT NOT NULL, updatedAt DOUBLE NOT NULL
      );
      CREATE TABLE publicationIntents (
          generationID TEXT PRIMARY KEY NOT NULL,
          runID TEXT NOT NULL REFERENCES runs(id), previousGenerationID TEXT,
          state TEXT NOT NULL, planFingerprint TEXT NOT NULL,
          artifactChecksum TEXT NOT NULL, createdAt DOUBLE NOT NULL, completedAt DOUBLE
      );
      """)
}
