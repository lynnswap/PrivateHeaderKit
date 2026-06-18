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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            self.toolVersion = try container.decode(String.self, forKey: .toolVersion)
            self.source = try container.decode(SourceRecord.self, forKey: .source)
            self.output = try container.decode(OutputRecord.self, forKey: .output)
            self.layout = try container.decode(Layout.self, forKey: .layout)
            self.latestRunID = try container.decodeRequiredNullable(String.self, forKey: .latestRunID)
            self.targets = try container.decode([TargetRecord].self, forKey: .targets)
            self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(toolVersion, forKey: .toolVersion)
            try container.encode(source, forKey: .source)
            try container.encode(output, forKey: .output)
            try container.encode(layout, forKey: .layout)
            try container.encodeRequired(latestRunID, forKey: .latestRunID)
            try container.encode(targets, forKey: .targets)
            try container.encode(updatedAt, forKey: .updatedAt)
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case toolVersion
            case source
            case output
            case layout
            case latestRunID
            case targets
            case updatedAt
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.platform = try container.decode(Source.Platform.self, forKey: .platform)
            self.version = try container.decode(String.self, forKey: .version)
            self.build = try container.decodeRequiredNullable(String.self, forKey: .build)
            self.displayName = try container.decode(String.self, forKey: .displayName)
            self.directoryName = try container.decode(String.self, forKey: .directoryName)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(platform, forKey: .platform)
            try container.encode(version, forKey: .version)
            try container.encodeRequired(build, forKey: .build)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(directoryName, forKey: .directoryName)
        }

        private enum CodingKeys: String, CodingKey {
            case platform
            case version
            case build
            case displayName
            case directoryName
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.displayName = try container.decode(String.self, forKey: .displayName)
            self.kind = try container.decode(String.self, forKey: .kind)
            self.status = try container.decode(TargetStatus.self, forKey: .status)
            self.phases = try container.decode([PhaseRecord].self, forKey: .phases)
            self.artifacts = try container.decode([ArtifactPath].self, forKey: .artifacts)
            self.lastRunID = try container.decodeRequiredNullable(String.self, forKey: .lastRunID)
            self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            self.failureSummary = try container.decodeRequiredNullable(String.self, forKey: .failureSummary)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(displayName, forKey: .displayName)
            try container.encode(kind, forKey: .kind)
            try container.encode(status, forKey: .status)
            try container.encode(phases, forKey: .phases)
            try container.encode(artifacts, forKey: .artifacts)
            try container.encodeRequired(lastRunID, forKey: .lastRunID)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encodeRequired(failureSummary, forKey: .failureSummary)
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName
            case kind
            case status
            case phases
            case artifacts
            case lastRunID
            case updatedAt
            case failureSummary
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.status = try container.decode(PhaseStatus.self, forKey: .status)
            self.failureSummary = try container.decodeRequiredNullable(String.self, forKey: .failureSummary)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(status, forKey: .status)
            try container.encodeRequired(failureSummary, forKey: .failureSummary)
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case status
            case failureSummary
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.runID = try container.decode(String.self, forKey: .runID)
            self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            self.toolVersion = try container.decode(String.self, forKey: .toolVersion)
            self.plan = try container.decode(RunPlanRecord.self, forKey: .plan)
            self.startedAt = try container.decode(Date.self, forKey: .startedAt)
            self.endedAt = try container.decodeRequiredNullable(Date.self, forKey: .endedAt)
            self.status = try container.decode(RunTargetStatus.self, forKey: .status)
            self.targetResults = try container.decode([RunTargetRecord].self, forKey: .targetResults)
            self.attemptedArtifacts = try container.decode([ArtifactPath].self, forKey: .attemptedArtifacts)
            self.logs = try container.decode([RunLogRecord].self, forKey: .logs)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(runID, forKey: .runID)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(toolVersion, forKey: .toolVersion)
            try container.encode(plan, forKey: .plan)
            try container.encode(startedAt, forKey: .startedAt)
            try container.encodeRequired(endedAt, forKey: .endedAt)
            try container.encode(status, forKey: .status)
            try container.encode(targetResults, forKey: .targetResults)
            try container.encode(attemptedArtifacts, forKey: .attemptedArtifacts)
            try container.encode(logs, forKey: .logs)
        }

        private enum CodingKeys: String, CodingKey {
            case runID
            case schemaVersion
            case toolVersion
            case plan
            case startedAt
            case endedAt
            case status
            case targetResults
            case attemptedArtifacts
            case logs
        }
    }

    struct RunPlanRecord: Codable, Equatable, Sendable {
        public let source: SourceRecord
        public let output: OutputRecord
        public let layout: Layout
        public let targetIDs: [String]
        public let execution: ExecutionRecord

        public init(
            source: SourceRecord,
            output: OutputRecord,
            layout: Layout,
            targetIDs: [String],
            execution: ExecutionRecord
        ) {
            self.source = source
            self.output = output
            self.layout = layout
            self.targetIDs = targetIDs
            self.execution = execution
        }
    }

    struct ExecutionRecord: Codable, Equatable, Sendable {
        public let mode: String
        public let runtimeIdentifier: String?
        public let deviceName: String?
        public let deviceUDID: String?
        public let clonePolicy: String?
        public let helperEnvironment: [String: String]

        public init(
            mode: String,
            runtimeIdentifier: String?,
            deviceName: String?,
            deviceUDID: String?,
            clonePolicy: String?,
            helperEnvironment: [String: String]
        ) {
            self.mode = mode
            self.runtimeIdentifier = runtimeIdentifier
            self.deviceName = deviceName
            self.deviceUDID = deviceUDID
            self.clonePolicy = clonePolicy
            self.helperEnvironment = helperEnvironment
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.mode = try container.decode(String.self, forKey: .mode)
            self.runtimeIdentifier = try container.decodeRequiredNullable(
                String.self,
                forKey: .runtimeIdentifier
            )
            self.deviceName = try container.decodeRequiredNullable(String.self, forKey: .deviceName)
            self.deviceUDID = try container.decodeRequiredNullable(String.self, forKey: .deviceUDID)
            self.clonePolicy = try container.decodeRequiredNullable(String.self, forKey: .clonePolicy)
            self.helperEnvironment = try container.decode([String: String].self, forKey: .helperEnvironment)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(mode, forKey: .mode)
            try container.encodeRequired(runtimeIdentifier, forKey: .runtimeIdentifier)
            try container.encodeRequired(deviceName, forKey: .deviceName)
            try container.encodeRequired(deviceUDID, forKey: .deviceUDID)
            try container.encodeRequired(clonePolicy, forKey: .clonePolicy)
            try container.encode(helperEnvironment, forKey: .helperEnvironment)
        }

        private enum CodingKeys: String, CodingKey {
            case mode
            case runtimeIdentifier
            case deviceName
            case deviceUDID
            case clonePolicy
            case helperEnvironment
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.targetID = try container.decode(String.self, forKey: .targetID)
            self.status = try container.decode(RunTargetStatus.self, forKey: .status)
            self.phases = try container.decode([PhaseRecord].self, forKey: .phases)
            self.artifacts = try container.decode([ArtifactPath].self, forKey: .artifacts)
            self.attemptedArtifacts = try container.decode([ArtifactPath].self, forKey: .attemptedArtifacts)
            self.failureSummary = try container.decodeRequiredNullable(String.self, forKey: .failureSummary)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(targetID, forKey: .targetID)
            try container.encode(status, forKey: .status)
            try container.encode(phases, forKey: .phases)
            try container.encode(artifacts, forKey: .artifacts)
            try container.encode(attemptedArtifacts, forKey: .attemptedArtifacts)
            try container.encodeRequired(failureSummary, forKey: .failureSummary)
        }

        private enum CodingKeys: String, CodingKey {
            case targetID
            case status
            case phases
            case artifacts
            case attemptedArtifacts
            case failureSummary
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
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(date.timeIntervalSinceReferenceDate)
            }
            return encoder
        }

        private static func decoder() -> JSONDecoder {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Double.self) {
                    return Date(timeIntervalSinceReferenceDate: value)
                }
                let value = try container.decode(String.self)
                if let date = fractionalSecondsFormatter().date(from: value) ?? wholeSecondsFormatter().date(from: value) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 date: \(value)"
                )
            }
            return decoder
        }

        private static func fractionalSecondsFormatter() -> ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }

        private static func wholeSecondsFormatter() -> ISO8601DateFormatter {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter
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

private extension KeyedEncodingContainer {
    mutating func encodeRequired<Value: Encodable>(_ value: Value?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeRequiredNullable<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value? {
        guard contains(key) else {
            let context = DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Missing required nullable key: \(key.stringValue)"
            )
            throw DecodingError.keyNotFound(key, context)
        }
        return try decodeIfPresent(type, forKey: key)
    }
}
