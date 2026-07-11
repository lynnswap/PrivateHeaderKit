import Foundation

extension PrivateHeaderGeneration {
  package enum Layout: String, Codable, CaseIterable, Hashable, Sendable {
    case headers
    case bundle
  }

  package enum RunStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case running
    case completed
    case partial
    case failed
    case interrupted
  }

  package enum RunTargetStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case running
    case skipped
    case completed
    case partial
    case failed
    case interrupted

    var preservesLastSuccessfulArtifacts: Bool {
      switch self {
      case .partial, .failed, .interrupted:
        true
      case .pending, .running, .skipped, .completed:
        false
      }
    }

    var isSuccessfulOrSkipped: Bool {
      self == .completed || self == .skipped
    }
  }

  package enum PublicationState: String, Codable, CaseIterable, Hashable, Sendable {
    case prepared
    case pointerPublished
    case committed
    case aborted
  }

  package struct RunID: RawRepresentable, Codable, CustomStringConvertible, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) {
      precondition(Self.isSafeComponent(rawValue), "invalid run ID")
      self.rawValue = rawValue
    }

    package init(_ rawValue: String) throws {
      guard Self.isSafeComponent(rawValue) else {
        throw StateError.invalidIdentifier(kind: "run", value: rawValue)
      }
      self.rawValue = rawValue
    }

    package var description: String { rawValue }

    package static func isSafeComponent(_ value: String) -> Bool {
      !value.isEmpty
        && value != "."
        && value != ".."
        && !value.contains("/")
        && !value.contains("\0")
    }
  }

  package struct GenerationID: RawRepresentable, Codable, CustomStringConvertible, Hashable,
    Sendable
  {
    package let rawValue: String

    package init(rawValue: String) {
      precondition(RunID.isSafeComponent(rawValue), "invalid generation ID")
      self.rawValue = rawValue
    }

    package init(_ rawValue: String) throws {
      guard RunID.isSafeComponent(rawValue) else {
        throw StateError.invalidIdentifier(kind: "generation", value: rawValue)
      }
      self.rawValue = rawValue
    }

    package var description: String { rawValue }
  }

  package struct ArtifactPath: RawRepresentable, Codable, CustomStringConvertible, Hashable,
    Sendable
  {
    package let rawValue: String

    package init(rawValue: String) {
      precondition(Self.isSafeRelativePath(rawValue), "invalid artifact path")
      self.rawValue = rawValue
    }

    package init(_ rawValue: String) throws {
      guard Self.isSafeRelativePath(rawValue) else {
        throw StateError.invalidArtifactPath(rawValue)
      }
      self.rawValue = rawValue
    }

    package var description: String { rawValue }

    package static func isSafeRelativePath(_ value: String) -> Bool {
      guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0") else {
        return false
      }
      return
        value
        .split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
  }

  package struct RunPlan: Hashable, Sendable {
    package let sourceIdentity: String
    package let fingerprint: String
    package let targetIDs: [String]
    package let toolVersion: String

    package init(
      sourceIdentity: String,
      fingerprint: String,
      targetIDs: [String],
      toolVersion: String
    ) {
      self.sourceIdentity = sourceIdentity
      self.fingerprint = fingerprint
      self.targetIDs = targetIDs
      self.toolVersion = toolVersion
    }
  }

  package struct TargetAttemptResult: Equatable, Sendable {
    package let targetID: String
    package let displayName: String
    package let kind: String
    package let status: RunTargetStatus
    package let artifacts: [ArtifactPath]
    package let failureSummary: String?
    package let completedAt: Date

    package init(
      targetID: String,
      displayName: String,
      kind: String,
      status: RunTargetStatus,
      artifacts: [ArtifactPath] = [],
      failureSummary: String? = nil,
      completedAt: Date
    ) {
      precondition(
        status == .completed
          || status == .partial
          || status == .failed
          || status == .interrupted,
        "target attempts must end in a terminal attempted state"
      )
      self.targetID = targetID
      self.displayName = displayName
      self.kind = kind
      self.status = status
      self.artifacts = artifacts
      self.failureSummary = failureSummary
      self.completedAt = completedAt
    }
  }

  package struct TargetAttemptSnapshot: Equatable, Sendable {
    package let targetID: String
    package let displayName: String
    package let kind: String
    package let status: RunTargetStatus
    package let artifacts: [ArtifactPath]
    package let failureSummary: String?
  }

  package struct TargetSnapshot: Equatable, Sendable {
    package let targetID: String
    package let lastSuccessfulRunID: RunID
    package let status: RunTargetStatus
    package let artifacts: [ArtifactPath]
    package let updatedAt: Date
  }

  package struct TargetCounts: Equatable, Hashable, Sendable {
    package let total: Int
    package let pending: Int
    package let running: Int
    package let skipped: Int
    package let completed: Int
    package let partial: Int
    package let failed: Int
    package let interrupted: Int

    package init(targets: [TargetAttemptSnapshot]) {
      total = targets.count
      pending = targets.count { $0.status == .pending }
      running = targets.count { $0.status == .running }
      skipped = targets.count { $0.status == .skipped }
      completed = targets.count { $0.status == .completed }
      partial = targets.count { $0.status == .partial }
      failed = targets.count { $0.status == .failed }
      interrupted = targets.count { $0.status == .interrupted }
    }

    package init(
      total: Int = 0,
      pending: Int = 0,
      running: Int = 0,
      skipped: Int = 0,
      completed: Int = 0,
      partial: Int = 0,
      failed: Int = 0,
      interrupted: Int = 0
    ) {
      self.total = total
      self.pending = pending
      self.running = running
      self.skipped = skipped
      self.completed = completed
      self.partial = partial
      self.failed = failed
      self.interrupted = interrupted
    }

    package var unfinished: Int {
      pending + running + partial + failed + interrupted
    }
  }

  package struct RunSnapshot: Equatable, Sendable {
    package let id: RunID
    package let sourceIdentity: String
    package let planFingerprint: String
    package let targetIDs: [String]
    package let startedAt: Date
    package let endedAt: Date?
    package let status: RunStatus
    package let targets: [TargetAttemptSnapshot]

    package var counts: TargetCounts { TargetCounts(targets: targets) }
  }

  package struct ResumeTargetDecision: Equatable, Sendable {
    package let targetID: String
    package let status: RunTargetStatus

    package var shouldRun: Bool { status != .completed }
  }

  package struct ResumeSummary: Equatable, Sendable {
    package let latestRunID: RunID
    package let startedAt: Date
    package let updatedAt: Date
    package let targets: [ResumeTargetDecision]

    package var counts: TargetCounts {
      TargetCounts(
        targets: targets.map {
          TargetAttemptSnapshot(
            targetID: $0.targetID,
            displayName: $0.targetID,
            kind: "",
            status: $0.status,
            artifacts: [],
            failureSummary: nil
          )
        }
      )
    }

    package var isUnfinished: Bool {
      targets.contains(where: \.shouldRun)
    }
  }

  package struct PublicationIntent: Equatable, Sendable {
    package let generationID: GenerationID
    package let runID: RunID
    package let previousGenerationID: GenerationID?
    package let state: PublicationState
    package let planFingerprint: String
    package let artifactChecksum: String
    package let createdAt: Date
    package let completedAt: Date?
  }

  package enum StablePathState: Equatable, Sendable {
    case absent
    case managed
    case legacyDirectory
  }

  package struct GenerationMarkerSnapshot: Equatable, Sendable {
    package let generationID: GenerationID
    package let planFingerprint: String
    package let artifactChecksum: String
    package let artifactsByTarget: [String: [ArtifactPath]]
    package let opaquePaths: [ArtifactPath]
  }

  package struct PublicationSnapshot: Equatable, Sendable {
    package let currentGenerationID: GenerationID?
    package let stablePathState: StablePathState
    package let markers: [GenerationID: GenerationMarkerSnapshot]

    package init(
      currentGenerationID: GenerationID?,
      stablePathState: StablePathState,
      markers: [GenerationID: GenerationMarkerSnapshot]
    ) {
      self.currentGenerationID = currentGenerationID
      self.stablePathState = stablePathState
      self.markers = markers
    }

    package var validGenerationIDs: Set<GenerationID> { Set(markers.keys) }
    package var currentMarker: GenerationMarkerSnapshot? {
      currentGenerationID.flatMap { markers[$0] }
    }
  }

  package enum RecoveryAction: Equatable, Sendable {
    case none
    case recognized(GenerationID?)
    case discardGeneration(GenerationID)
    case completeStablePointer(GenerationID)
    case rolledForward(GenerationID)
  }

  package enum RecoveryTerminalReason: Equatable, Sendable {
    case interrupted
    case failed(message: String)
  }

  package enum StoreFaultPoint: Equatable, Sendable {
    case afterRunTargetWrite
    case afterPublicationIntentWrite
    case afterSemanticFinalize
    case beforeTerminalRunCommit
    case beforeRunLogWrite
  }

  package enum PublicationFaultPoint: Equatable, Sendable {
    case afterPrepared
    case afterGenerationMove
    case afterCurrentPointerSwitch
    case afterStablePointerSwitch
    case beforeCommitted
  }

  package enum StateError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidIdentifier(kind: String, value: String)
    case invalidArtifactPath(String)
    case invalidTransition(entity: String, from: String, to: String)
    case missingRun(RunID)
    case missingPublicationIntent(GenerationID)
    case corruptPublication(String)
    case unsupportedMigrations([String])

    package var description: String {
      switch self {
      case .invalidIdentifier(let kind, let value):
        "invalid \(kind) identifier: \(value)"
      case .invalidArtifactPath(let path):
        "artifact path is not safe: \(path)"
      case .invalidTransition(let entity, let from, let to):
        "invalid \(entity) transition from \(from) to \(to)"
      case .missingRun(let runID):
        "generation run does not exist: \(runID.rawValue)"
      case .missingPublicationIntent(let generationID):
        "publication intent does not exist: \(generationID.rawValue)"
      case .corruptPublication(let message):
        "publication state is corrupt: \(message)"
      case .unsupportedMigrations(let identifiers):
        "generation database contains unsupported migrations: \(identifiers.joined(separator: ", "))"
      }
    }
  }
}
