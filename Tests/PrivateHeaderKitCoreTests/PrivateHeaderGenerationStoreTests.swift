import Foundation
import GRDB
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationStoreTests {
  private enum InjectedFault: Error {
    case stop
  }

  @Test func migratesVersionOneDatabaseAndRecordsCurrentSchema() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("generation.sqlite")
    let queue = try DatabaseQueue(path: databaseURL.path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-generation-state") { db in
      try createVersionOneSchema(db)
    }
    try migrator.migrate(queue)

    let store = try GenerationStore(databaseURL: databaseURL, toolCompatibilityIdentity: "test")
    #expect(
      try await store.appliedMigrationIdentifiers() == [
        "v1-generation-state",
        "v2-run-logs-and-indexes",
        "v3-causal-ordering",
        "v4-published-artifact-digests",
      ])
    let columns = try await queue.read { db in
      try db.columns(in: "runLogs").map(\.name)
    }
    #expect(columns.contains("message"))
    #expect(
      try await queue.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = 'schemaVersion'")
      } == nil)
  }

  @Test func unknownFutureMigrationFailsFastBeforeMigration() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("generation.sqlite")
    _ = try GenerationStore(databaseURL: databaseURL, toolCompatibilityIdentity: "test")
    let queue = try DatabaseQueue(path: databaseURL.path)
    try await queue.write { db in
      try db.execute(
        sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
        arguments: ["v999-future"]
      )
    }

    do {
      _ = try GenerationStore(databaseURL: databaseURL, toolCompatibilityIdentity: "test")
      Issue.record("future migration was unexpectedly accepted")
    } catch let error as PrivateHeaderGeneration.StateError {
      #expect(error == .unsupportedMigrations(["v999-future"]))
    }
  }

  @Test func targetAttemptFaultRollsBackWholeDomainTransaction() async throws {
    let fixture = try StoreFixture(fault: { point in
      if point == .afterRunTargetWrite { throw InjectedFault.stop }
    })
    defer { fixture.cleanup() }
    let runID = PrivateHeaderGeneration.RunID(rawValue: "run-rollback")
    _ = try await fixture.store.beginRun(
      id: runID,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: fixture.date
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: runID,
      at: fixture.date
    )

    do {
      try await fixture.store.recordTargetAttempt(
        fixture.completedTarget("framework:Foo"),
        in: runID
      )
      Issue.record("fault-injected target transaction unexpectedly committed")
    } catch InjectedFault.stop {}

    let run = try await fixture.store.runSnapshot(runID)
    #expect(run.targets.first?.status == .running)
    #expect(run.targets.first?.artifacts.isEmpty == true)
  }

  @Test func publicationFinalizeFaultRollsBackRunTargetAndIntentChanges() async throws {
    let fixture = try StoreFixture(fault: { point in
      if point == .afterSemanticFinalize { throw InjectedFault.stop }
    })
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(ids.generationID)

    do {
      _ = try await fixture.store.completePublication(ids.generationID, at: fixture.date)
      Issue.record("fault-injected publication unexpectedly committed")
    } catch InjectedFault.stop {}

    let run = try await fixture.store.runSnapshot(ids.runID)
    #expect(run.status == .running)
    #expect(try await fixture.store.targetSnapshot(targetID: "framework:Foo") == nil)
    #expect(
      try await fixture.store.publicationIntent(generationID: ids.generationID)?.state
        == .pointerPublished)
  }

  @Test func committedPublicationUpdatesRunTargetAndIntentAtomically() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(ids.generationID)
    let run = try await fixture.store.completePublication(ids.generationID, at: fixture.date)

    #expect(run.status == .completed)
    #expect(
      try await fixture.store.targetSnapshot(targetID: "framework:Foo")?.lastSuccessfulRunID
        == ids.runID)
    #expect(
      try await fixture.store.publicationIntent(generationID: ids.generationID)?.state == .committed
    )
  }

  @Test func committedIntentRepairsMissingStablePointer() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(ids.generationID)
    _ = try await fixture.store.completePublication(ids.generationID, at: fixture.date)

    let action = try await fixture.store.recover(
      using: .init(
        currentGenerationID: ids.generationID,
        stablePathState: .absent,
        markers: [ids.generationID: fixture.marker(ids.generationID)]
      ),
      at: fixture.date
    )

    #expect(action == .completeStablePointer(ids.generationID))
    #expect(
      try await fixture.store.publicationIntent(generationID: ids.generationID)?.state == .committed
    )
  }

  @Test func publishedTargetAttemptBecomesImmediatelyResumable() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = PrivateHeaderGeneration.RunID(rawValue: "run-incremental")
    _ = try await fixture.store.beginRun(
      id: runID,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: fixture.date
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: runID,
      at: fixture.date
    )
    let completed = fixture.completedTarget("framework:Foo")

    try await fixture.store.prepareTargetPublication(completed, in: runID)
    try await fixture.store.recordPublishedTargetAttempt(
      completed,
      artifactDigests: [
        PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Foo.h"):
          String(repeating: "0", count: 64)
      ],
      in: runID
    )

    #expect(try await fixture.store.runSnapshot(runID).status == .running)
    #expect(try await fixture.store.runSnapshot(runID).targets.first?.status == .completed)
    #expect(
      try await fixture.store.targetSnapshot(targetID: "framework:Foo")?.lastSuccessfulRunID
        == runID
    )
    #expect(
      try await fixture.store.publishedArtifactsByTarget()["framework:Foo"]
        == completed.artifacts
    )
  }

  @Test func committedIntentRejectsMismatchedCurrentMarker() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(ids.generationID)
    _ = try await fixture.store.completePublication(ids.generationID, at: fixture.date)
    let mismatched = PrivateHeaderGeneration.GenerationMarkerSnapshot(
      generationID: ids.generationID,
      planFingerprint: "fingerprint",
      artifactChecksum: "different-checksum",
      artifactsByTarget: [:],
      opaquePaths: []
    )

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: ids.generationID,
          stablePathState: .managed,
          markers: [ids.generationID: mismatched]
        ),
        at: fixture.date
      )
    }
  }

  @Test func committedIntentRejectsUnmanagedStableDirectory() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(ids.generationID)
    _ = try await fixture.store.completePublication(ids.generationID, at: fixture.date)

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: ids.generationID,
          stablePathState: .legacyDirectory,
          markers: [ids.generationID: fixture.marker(ids.generationID)]
        ),
        at: fixture.date
      )
    }
  }

  @Test func preparedIntentWithPreviousCurrentAbortsAsInterrupted() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication(
      previousGenerationID: .init(rawValue: "generation-old")
    )
    let marker = fixture.marker(ids.generationID)
    let action = try await fixture.store.recover(
      using: .init(
        currentGenerationID: .init(rawValue: "generation-old"),
        stablePathState: .managed,
        markers: [ids.generationID: marker]
      ),
      at: fixture.date
    )

    #expect(action == .discardGeneration(ids.generationID))
    #expect(try await fixture.store.runSnapshot(ids.runID).status == .interrupted)
    #expect(try await fixture.store.targetSnapshot(targetID: "framework:Foo") == nil)
    #expect(
      try await fixture.store.publicationIntent(generationID: ids.generationID)?.state == .aborted)

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: ids.generationID,
          stablePathState: .managed,
          markers: [ids.generationID: marker]
        ),
        at: fixture.date
      )
    }
  }

  @Test func abortedIntentRetriesDiscardUntilGenerationIsAbsent() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let previousGenerationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    let ids = try await fixture.prepareCompletedPublication(
      previousGenerationID: previousGenerationID
    )
    let previousMarker = fixture.marker(previousGenerationID)
    let abortedMarker = fixture.marker(ids.generationID)
    let interruptedSnapshot = PrivateHeaderGeneration.PublicationSnapshot(
      currentGenerationID: previousGenerationID,
      stablePathState: .managed,
      markers: [
        previousGenerationID: previousMarker,
        ids.generationID: abortedMarker,
      ]
    )

    #expect(
      try await fixture.store.recover(using: interruptedSnapshot, at: fixture.date)
        == .discardGeneration(ids.generationID)
    )
    #expect(
      try await fixture.store.recover(using: interruptedSnapshot, at: fixture.date)
        == .discardGeneration(ids.generationID)
    )
    #expect(
      try await fixture.store.recover(
        using: .init(
          currentGenerationID: previousGenerationID,
          stablePathState: .managed,
          markers: [previousGenerationID: previousMarker]
        ),
        at: fixture.date
      ) == .recognized(previousGenerationID)
    )
  }

  @Test func abortedLegacyMigrationRetriesDiscardUntilGenerationIsAbsent() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication(previousGenerationID: nil)
    let interruptedSnapshot = PrivateHeaderGeneration.PublicationSnapshot(
      currentGenerationID: nil,
      stablePathState: .legacyDirectory,
      markers: [ids.generationID: fixture.marker(ids.generationID)]
    )

    #expect(
      try await fixture.store.recover(using: interruptedSnapshot, at: fixture.date)
        == .discardGeneration(ids.generationID)
    )
    #expect(
      try await fixture.store.recover(using: interruptedSnapshot, at: fixture.date)
        == .discardGeneration(ids.generationID)
    )
    #expect(
      try await fixture.store.recover(
        using: .init(
          currentGenerationID: nil,
          stablePathState: .legacyDirectory,
          markers: [:]
        ),
        at: fixture.date
      ) == .recognized(nil)
    )
  }

  @Test func abortedIntentRejectsMissingPreviousCurrentPointer() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let previousGenerationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    let ids = try await fixture.prepareCompletedPublication(
      previousGenerationID: previousGenerationID
    )
    _ = try await fixture.store.recover(
      using: .init(
        currentGenerationID: previousGenerationID,
        stablePathState: .managed,
        markers: [
          previousGenerationID: fixture.marker(previousGenerationID),
          ids.generationID: fixture.marker(ids.generationID),
        ]
      ),
      at: fixture.date
    )

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: nil,
          stablePathState: .absent,
          markers: [:]
        ),
        at: fixture.date
      )
    }
  }

  @Test func abortedIntentRejectsUnrelatedCurrentPointer() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let previousGenerationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    let unrelatedGenerationID = PrivateHeaderGeneration.GenerationID(
      rawValue: "generation-unrelated"
    )
    let ids = try await fixture.prepareCompletedPublication(
      previousGenerationID: previousGenerationID
    )
    _ = try await fixture.store.recover(
      using: .init(
        currentGenerationID: previousGenerationID,
        stablePathState: .managed,
        markers: [
          previousGenerationID: fixture.marker(previousGenerationID),
          ids.generationID: fixture.marker(ids.generationID),
        ]
      ),
      at: fixture.date
    )

    await #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: unrelatedGenerationID,
          stablePathState: .managed,
          markers: [unrelatedGenerationID: fixture.marker(unrelatedGenerationID)]
        ),
        at: fixture.date
      )
    }
  }

  @Test func controlledPreparedAbortFailsActiveTargetAndRetainsPendingRows() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = PrivateHeaderGeneration.RunID(rawValue: "run-controlled-failure")
    _ = try await fixture.store.beginRun(
      id: runID,
      plan: fixture.plan(targetIDs: ["framework:Foo", "framework:Bar"]),
      at: fixture.date
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: runID,
      at: fixture.date
    )
    try await fixture.store.recordTargetAttempt(
      fixture.completedTarget("framework:Foo"),
      in: runID
    )
    let generationID = PrivateHeaderGeneration.GenerationID(
      rawValue: "generation-controlled-failure")
    let previousGenerationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    _ = try await fixture.store.preparePublication(
      generationID: generationID,
      runID: runID,
      previousGenerationID: previousGenerationID,
      planFingerprint: "fingerprint",
      artifactChecksum: "checksum",
      at: fixture.date
    )

    let action = try await fixture.store.recover(
      using: .init(
        currentGenerationID: previousGenerationID,
        stablePathState: .managed,
        markers: [:]
      ),
      at: fixture.date,
      terminalReason: .failed(message: "generation move failed")
    )

    #expect(action == .discardGeneration(generationID))
    let run = try await fixture.store.runSnapshot(runID)
    #expect(run.status == .failed)
    let targets = Dictionary(uniqueKeysWithValues: run.targets.map { ($0.targetID, $0) })
    #expect(targets["framework:Foo"]?.status == .failed)
    #expect(targets["framework:Foo"]?.failureSummary == "generation move failed")
    #expect(targets["framework:Bar"]?.status == .pending)
    #expect(
      try await fixture.store.publicationIntent(generationID: generationID)?.state == .aborted)
  }

  @Test func pointerPublishedIntentCanNotMoveBackToPreviousCurrent() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let oldID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    let ids = try await fixture.prepareCompletedPublication(previousGenerationID: oldID)
    try await fixture.store.markPointerPublished(ids.generationID)

    do {
      _ = try await fixture.store.recover(
        using: .init(
          currentGenerationID: oldID,
          stablePathState: .managed,
          markers: [ids.generationID: fixture.marker(ids.generationID)]
        ),
        at: fixture.date
      )
      Issue.record("pointerPublished mismatch unexpectedly recovered")
    } catch let error as PrivateHeaderGeneration.StateError {
      guard case .corruptPublication = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }
  }

  @Test func recoveryCompletesStablePointerThenRollsForwardIdempotently() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication()
    let marker = fixture.marker(ids.generationID)
    let incomplete = PrivateHeaderGeneration.PublicationSnapshot(
      currentGenerationID: ids.generationID,
      stablePathState: .absent,
      markers: [ids.generationID: marker]
    )
    #expect(
      try await fixture.store.recover(using: incomplete, at: fixture.date)
        == .completeStablePointer(ids.generationID))

    let complete = PrivateHeaderGeneration.PublicationSnapshot(
      currentGenerationID: ids.generationID,
      stablePathState: .managed,
      markers: [ids.generationID: marker]
    )
    #expect(
      try await fixture.store.recover(using: complete, at: fixture.date)
        == .rolledForward(ids.generationID))
    #expect(try await fixture.store.recover(using: complete, at: fixture.date) == .none)
    #expect(try await fixture.store.runSnapshot(ids.runID).status == .completed)
  }

  @Test func resumeAllowsTargetExpansionAndRejectsShrink() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let ids = try await fixture.prepareCompletedPublication(targetIDs: ["framework:Foo"])
    try await fixture.store.markPointerPublished(ids.generationID)
    _ = try await fixture.store.completePublication(ids.generationID, at: fixture.date)
    let current = [
      "framework:Foo": [try PrivateHeaderGeneration.ArtifactPath("Frameworks/Foo/Foo.h")]
    ]

    let expanded = try await fixture.store.resumeSummary(
      planFingerprint: "fingerprint",
      selectedTargetIDs: ["framework:Foo", "framework:Bar"],
      currentArtifactsByTarget: current,
      at: fixture.date
    )
    #expect(expanded?.targets.map(\.status) == [.completed, .pending])

    do {
      _ = try await fixture.store.resumeSummary(
        planFingerprint: "fingerprint",
        selectedTargetIDs: [],
        currentArtifactsByTarget: current,
        at: fixture.date
      )
      Issue.record("shrinking target set unexpectedly resumed")
    } catch let error as PrivateHeaderGeneration.GenerationError {
      guard case .incompatibleResume = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }
  }

  @Test func completedAttemptRequiresTransactionalPublicationOwnershipToResumeAsComplete()
    async throws
  {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let first = try await fixture.prepareCompletedPublication()
    try await fixture.store.markPointerPublished(first.generationID)
    _ = try await fixture.store.completePublication(first.generationID, at: fixture.date)

    let secondRunID = PrivateHeaderGeneration.RunID(rawValue: "run-unpublished")
    _ = try await fixture.store.beginRun(
      id: secondRunID,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: fixture.date
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: secondRunID,
      at: fixture.date
    )
    try await fixture.store.recordTargetAttempt(
      fixture.completedTarget("framework:Foo"),
      in: secondRunID
    )
    let secondGenerationID = PrivateHeaderGeneration.GenerationID(
      rawValue: "generation-unpublished"
    )
    _ = try await fixture.store.preparePublication(
      generationID: secondGenerationID,
      runID: secondRunID,
      previousGenerationID: first.generationID,
      planFingerprint: "fingerprint",
      artifactChecksum: "checksum-new",
      at: fixture.date
    )
    #expect(
      try await fixture.store.recover(
        using: .init(
          currentGenerationID: first.generationID,
          stablePathState: .managed,
          markers: [first.generationID: fixture.marker(first.generationID)]
        ),
        at: fixture.date
      ) == .discardGeneration(secondGenerationID)
    )

    let summary = try #require(
      try await fixture.store.resumeSummary(
        planFingerprint: "fingerprint",
        selectedTargetIDs: ["framework:Foo"],
        currentArtifactsByTarget: fixture.marker(first.generationID).artifactsByTarget,
        at: fixture.date
      )
    )
    #expect(summary.targets == [.init(targetID: "framework:Foo", status: .pending)])
  }

  @Test func interruptionIsIdempotentAndNeverBecomesFailure() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let runID = PrivateHeaderGeneration.RunID(rawValue: "run-interrupt")
    _ = try await fixture.store.beginRun(
      id: runID,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: fixture.date
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: runID,
      at: fixture.date
    )
    #expect(try await fixture.store.markInterrupted(runID, at: fixture.date).status == .interrupted)
    #expect(try await fixture.store.markInterrupted(runID, at: fixture.date).status == .interrupted)
    #expect(try await fixture.store.runSnapshot(runID).targets.first?.status == .interrupted)
  }

  @Test func databaseSymlinkIsRejectedBeforeGRDBOpen() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real.sqlite")
    FileManager.default.createFile(atPath: real.path, contents: Data())
    let link = root.appendingPathComponent("generation.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    #expect(throws: PrivateHeaderGeneration.StateError.self) {
      _ = try GenerationStore(databaseURL: link, toolCompatibilityIdentity: "test")
    }
  }

  @Test func malformedPersistedIdentifierThrowsInsteadOfTrapping() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("generation.sqlite")
    let store = try GenerationStore(databaseURL: databaseURL, toolCompatibilityIdentity: "test")
    let queue = try DatabaseQueue(path: databaseURL.path)
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO runs(
              id, sourceIdentity, planFingerprint, targetIDs,
              startedAt, endedAt, status, terminalStatusOverride
          ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
          """,
        arguments: ["../unsafe", "macOS|16.0|25A", "fingerprint", "[]", 1.0, 1.0, "completed"]
      )
      try db.execute(
        sql: "INSERT INTO runOrdering(runID) VALUES (?)",
        arguments: ["../unsafe"]
      )
    }

    do {
      _ = try await store.latestRunSnapshot()
      Issue.record("malformed persisted run ID unexpectedly decoded")
    } catch let error as PrivateHeaderGeneration.StateError {
      #expect(error == .invalidIdentifier(kind: "run", value: "../unsafe"))
    }
  }

  @Test func latestRunAndIntentUseDatabaseSequenceInsteadOfWallClock() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanup() }
    let lateDate = Date(timeIntervalSinceReferenceDate: 500)
    let earlyDate = Date(timeIntervalSinceReferenceDate: 100)

    let firstRun = PrivateHeaderGeneration.RunID(rawValue: "run-inserted-first")
    _ = try await fixture.store.beginRun(
      id: firstRun,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: lateDate
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: firstRun,
      at: lateDate
    )
    try await fixture.store.recordTargetAttempt(
      fixture.completedTarget("framework:Foo", at: lateDate),
      in: firstRun
    )
    let firstGeneration = PrivateHeaderGeneration.GenerationID(
      rawValue: "generation-inserted-first")
    _ = try await fixture.store.preparePublication(
      generationID: firstGeneration,
      runID: firstRun,
      previousGenerationID: nil,
      planFingerprint: "fingerprint",
      artifactChecksum: "first",
      at: lateDate
    )
    try await fixture.store.markPointerPublished(firstGeneration)
    _ = try await fixture.store.completePublication(firstGeneration, at: lateDate)

    let secondRun = PrivateHeaderGeneration.RunID(rawValue: "run-inserted-second")
    _ = try await fixture.store.beginRun(
      id: secondRun,
      plan: fixture.plan(targetIDs: ["framework:Foo"]),
      at: earlyDate
    )
    try await fixture.store.beginTargetAttempt(
      targetID: "framework:Foo",
      displayName: "Foo",
      kind: "framework",
      in: secondRun,
      at: earlyDate
    )
    try await fixture.store.recordTargetAttempt(
      fixture.completedTarget("framework:Foo", at: earlyDate),
      in: secondRun
    )
    let secondGeneration = PrivateHeaderGeneration.GenerationID(
      rawValue: "generation-inserted-second")
    _ = try await fixture.store.preparePublication(
      generationID: secondGeneration,
      runID: secondRun,
      previousGenerationID: firstGeneration,
      planFingerprint: "fingerprint",
      artifactChecksum: "second",
      at: earlyDate
    )
    try await fixture.store.markPointerPublished(secondGeneration)
    _ = try await fixture.store.completePublication(secondGeneration, at: earlyDate)

    #expect(try await fixture.store.latestRunSnapshot()?.id == secondRun)
    #expect(
      try await fixture.store.recover(
        using: .init(
          currentGenerationID: secondGeneration,
          stablePathState: .managed,
          markers: [
            secondGeneration: .init(
              generationID: secondGeneration,
              planFingerprint: "fingerprint",
              artifactChecksum: "second",
              artifactsByTarget: [:],
              opaquePaths: []
            )
          ]
        ),
        at: earlyDate
      ) == .none)
  }
}

private final class StoreFixture: @unchecked Sendable {
  let root: URL
  let databaseURL: URL
  let store: GenerationStore
  let date = Date(timeIntervalSinceReferenceDate: 100)

  init(fault: @escaping GenerationStore.FaultInjector = { _ in }) throws {
    root = try temporaryDirectory()
    databaseURL = root.appendingPathComponent("generation.sqlite")
    store = try GenerationStore(
      databaseURL: databaseURL, toolCompatibilityIdentity: "test", faultInjector: fault)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func plan(targetIDs: [String]) -> PrivateHeaderGeneration.RunPlan {
    .init(
      sourceIdentity: "iOS|27.0|24A",
      fingerprint: "fingerprint",
      targetIDs: targetIDs,
      toolCompatibilityIdentity: "test"
    )
  }

  func completedTarget(
    _ targetID: String,
    at completedAt: Date? = nil
  ) -> PrivateHeaderGeneration.TargetAttemptResult {
    .init(
      targetID: targetID,
      displayName: targetID,
      kind: "framework",
      status: .completed,
      artifacts: [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Foo.h")],
      completedAt: completedAt ?? date
    )
  }

  func prepareCompletedPublication(
    previousGenerationID: PrivateHeaderGeneration.GenerationID? = nil,
    targetIDs: [String] = ["framework:Foo"]
  ) async throws -> (
    runID: PrivateHeaderGeneration.RunID, generationID: PrivateHeaderGeneration.GenerationID
  ) {
    let runID = PrivateHeaderGeneration.RunID(rawValue: "run-publication")
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-new")
    _ = try await store.beginRun(id: runID, plan: plan(targetIDs: targetIDs), at: date)
    for targetID in targetIDs {
      try await store.beginTargetAttempt(
        targetID: targetID,
        displayName: targetID,
        kind: "framework",
        in: runID,
        at: date
      )
      try await store.recordTargetAttempt(completedTarget(targetID), in: runID)
    }
    _ = try await store.preparePublication(
      generationID: generationID,
      runID: runID,
      previousGenerationID: previousGenerationID,
      planFingerprint: "fingerprint",
      artifactChecksum: "checksum",
      at: date
    )
    return (runID, generationID)
  }

  func marker(
    _ generationID: PrivateHeaderGeneration.GenerationID
  ) -> PrivateHeaderGeneration.GenerationMarkerSnapshot {
    .init(
      generationID: generationID,
      planFingerprint: "fingerprint",
      artifactChecksum: "checksum",
      artifactsByTarget: [
        "framework:Foo": [PrivateHeaderGeneration.ArtifactPath(rawValue: "Frameworks/Foo/Foo.h")]
      ],
      opaquePaths: []
    )
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
