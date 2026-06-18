import Foundation

public extension PrivateHeaderGeneration {
    enum Layout: String, Codable, CaseIterable, Hashable, Sendable {
        case headers
        case bundle
    }

    enum TargetStatus: String, Codable, CaseIterable, Hashable, Sendable {
        case completed
        case partial
        case failed
        case interrupted
        case commitFailed
        case stale
    }

    enum RunTargetStatus: String, Codable, CaseIterable, Hashable, Sendable {
        case pending
        case running
        case skipped
        case completed
        case partial
        case failed
        case interrupted
        case commitFailed
    }

    enum PhaseStatus: String, Codable, CaseIterable, Hashable, Sendable {
        case pending
        case running
        case completed
        case failed
        case skipped
    }

    struct ArtifactPath: Codable, CustomStringConvertible, Hashable, Sendable {
        public let rawValue: String

        public init(_ rawValue: String) throws {
            try Self.validate(rawValue)
            self.rawValue = rawValue
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            try Self.validate(rawValue)
            self.rawValue = rawValue
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public var description: String {
            rawValue
        }

        private static func validate(_ rawValue: String) throws {
            guard !rawValue.isEmpty else {
                throw StateValidationError.emptyArtifactPath
            }
            guard !rawValue.hasPrefix("/") else {
                throw StateValidationError.absoluteArtifactPath(rawValue)
            }
            guard !rawValue.contains("\0") else {
                throw StateValidationError.invalidArtifactPath(rawValue)
            }

            let components = rawValue.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw StateValidationError.invalidArtifactPath(rawValue)
            }
        }
    }

    enum StateValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case emptyArtifactPath
        case absoluteArtifactPath(String)
        case invalidArtifactPath(String)

        public var description: String {
            switch self {
            case .emptyArtifactPath:
                "artifact path must not be empty"
            case .absoluteArtifactPath(let path):
                "artifact path must be relative: \(path)"
            case .invalidArtifactPath(let path):
                "artifact path is not safe: \(path)"
            }
        }
    }
}

public extension PrivateHeaderGeneration {
    struct Manifest: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let toolVersion: String
        public let source: SourceRecord
        public let output: OutputRecord
        public let layout: Layout
        public let latestRunID: String?
        public let targets: [TargetRecord]
        public let updatedAt: Date

        public init(
            schemaVersion: Int,
            toolVersion: String,
            source: SourceRecord,
            output: OutputRecord,
            layout: Layout,
            latestRunID: String?,
            targets: [TargetRecord],
            updatedAt: Date
        ) {
            self.schemaVersion = schemaVersion
            self.toolVersion = toolVersion
            self.source = source
            self.output = output
            self.layout = layout
            self.latestRunID = latestRunID
            self.targets = targets
            self.updatedAt = updatedAt
        }
    }

    struct SourceRecord: Codable, Equatable, Sendable {
        public let platform: Source.Platform
        public let version: String
        public let build: String?
        public let displayName: String
        public let directoryName: String

        public init(source: Source) {
            self.platform = source.platform
            self.version = source.version
            self.build = source.build
            self.displayName = source.label.displayName
            self.directoryName = source.label.directoryName
        }
    }

    struct OutputRecord: Codable, Equatable, Sendable {
        public let baseDirectory: String
        public let artifactDirectory: String
        public let stateDirectory: String

        public init(
            baseDirectory: String,
            artifactDirectory: String,
            stateDirectory: String
        ) {
            self.baseDirectory = baseDirectory
            self.artifactDirectory = artifactDirectory
            self.stateDirectory = stateDirectory
        }

        public init(plan: Plan, baseDirectory: URL) {
            self.init(
                baseDirectory: baseDirectory.path,
                artifactDirectory: plan.artifactDirectory.path,
                stateDirectory: plan.stateDirectory.path
            )
        }
    }

    struct TargetRecord: Codable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let kind: String
        public let status: TargetStatus
        public let phases: [PhaseRecord]
        public let artifacts: [ArtifactPath]
        public let lastRunID: String?
        public let updatedAt: Date
        public let failureSummary: String?

        public init(
            id: String,
            displayName: String,
            kind: String,
            status: TargetStatus,
            phases: [PhaseRecord],
            artifacts: [ArtifactPath],
            lastRunID: String?,
            updatedAt: Date,
            failureSummary: String?
        ) {
            self.id = id
            self.displayName = displayName
            self.kind = kind
            self.status = status
            self.phases = phases
            self.artifacts = artifacts
            self.lastRunID = lastRunID
            self.updatedAt = updatedAt
            self.failureSummary = failureSummary
        }
    }

    struct PhaseRecord: Codable, Equatable, Sendable {
        public let name: String
        public let status: PhaseStatus
        public let failureSummary: String?

        public init(name: String, status: PhaseStatus, failureSummary: String? = nil) {
            self.name = name
            self.status = status
            self.failureSummary = failureSummary
        }
    }
}

public extension PrivateHeaderGeneration {
    struct RunRecord: Codable, Equatable, Sendable {
        public let runID: String
        public let schemaVersion: Int
        public let toolVersion: String
        public let plan: RunPlanRecord
        public let startedAt: Date
        public let endedAt: Date?
        public let status: RunTargetStatus
        public let targetResults: [RunTargetRecord]
        public let attemptedArtifacts: [ArtifactPath]
        public let logs: [RunLogRecord]

        public init(
            runID: String,
            schemaVersion: Int,
            toolVersion: String,
            plan: RunPlanRecord,
            startedAt: Date,
            endedAt: Date?,
            status: RunTargetStatus,
            targetResults: [RunTargetRecord],
            attemptedArtifacts: [ArtifactPath],
            logs: [RunLogRecord]
        ) {
            self.runID = runID
            self.schemaVersion = schemaVersion
            self.toolVersion = toolVersion
            self.plan = plan
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.status = status
            self.targetResults = targetResults
            self.attemptedArtifacts = attemptedArtifacts
            self.logs = logs
        }
    }

    struct RunPlanRecord: Codable, Equatable, Sendable {
        public let source: SourceRecord
        public let output: OutputRecord
        public let layout: Layout
        public let targetIDs: [String]

        public init(
            source: SourceRecord,
            output: OutputRecord,
            layout: Layout,
            targetIDs: [String]
        ) {
            self.source = source
            self.output = output
            self.layout = layout
            self.targetIDs = targetIDs
        }
    }

    struct RunTargetRecord: Codable, Equatable, Sendable {
        public let targetID: String
        public let status: RunTargetStatus
        public let phases: [PhaseRecord]
        public let artifacts: [ArtifactPath]
        public let attemptedArtifacts: [ArtifactPath]
        public let failureSummary: String?

        public init(
            targetID: String,
            status: RunTargetStatus,
            phases: [PhaseRecord],
            artifacts: [ArtifactPath],
            attemptedArtifacts: [ArtifactPath],
            failureSummary: String?
        ) {
            self.targetID = targetID
            self.status = status
            self.phases = phases
            self.artifacts = artifacts
            self.attemptedArtifacts = attemptedArtifacts
            self.failureSummary = failureSummary
        }
    }

    struct RunLogRecord: Codable, Equatable, Sendable {
        public let kind: String
        public let relativePath: ArtifactPath

        public init(kind: String, relativePath: ArtifactPath) {
            self.kind = kind
            self.relativePath = relativePath
        }
    }
}

public extension PrivateHeaderGeneration {
    enum StateJSON {
        public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
            try encoder().encode(value)
        }

        public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
            try decoder().decode(type, from: data)
        }

        public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
            let data = try encode(value)
            try data.write(to: url, options: [.atomic])
        }

        public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
            let data = try Data(contentsOf: url)
            return try decode(type, from: data)
        }

        private static func encoder() -> JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }

        private static func decoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }
    }

    struct RunSummary: Hashable, Sendable {
        public let runID: String
        public let startedAt: Date

        public init(runID: String, startedAt: Date) {
            self.runID = runID
            self.startedAt = startedAt
        }
    }

    enum RunHistoryRetention {
        public static func retainedRunIDs(
            from runs: [RunSummary],
            limit: Int = 10
        ) -> [String] {
            guard limit > 0 else {
                return []
            }

            return runs
                .sorted {
                    if $0.startedAt == $1.startedAt {
                        $0.runID > $1.runID
                    } else {
                        $0.startedAt > $1.startedAt
                    }
                }
                .prefix(limit)
                .map(\.runID)
        }
    }
}

extension PrivateHeaderGeneration.Source.Platform: Codable {}
