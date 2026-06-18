import Foundation

public enum PrivateHeaderGeneration {
    public static func makePlan(
        source: Source,
        output: Output,
        options: Options = Options()
    ) -> Plan {
        Plan(
            source: source,
            output: output,
            options: options
        )
    }

    public static func generatePrivateHeaders(
        source: Source,
        output: Output,
        options: Options = Options()
    ) async throws -> Result {
        let plan = makePlan(
            source: source,
            output: output,
            options: options
        )
        return try await GenerationExecutor().run(
            GenerationExecutor.Configuration(plan: plan)
        )
    }
}

public func generatePrivateHeaders(
    source: PrivateHeaderGeneration.Source,
    output: PrivateHeaderGeneration.Output,
    options: PrivateHeaderGeneration.Options = PrivateHeaderGeneration.Options()
) async throws -> PrivateHeaderGeneration.Result {
    try await PrivateHeaderGeneration.generatePrivateHeaders(
        source: source,
        output: output,
        options: options
    )
}

public extension PrivateHeaderGeneration {
    struct Source: Hashable, Sendable {
        public let platform: Platform
        public let version: String
        public let build: String?

        public init(platform: Platform, version: String, build: String? = nil) throws {
            try Self.validatePathComponent(version, field: "version")
            let build = build.flatMap { $0.isEmpty ? nil : $0 }
            if let build {
                try Self.validatePathComponent(build, field: "build")
            }
            self.platform = platform
            self.version = version
            self.build = build
        }

        public var label: Label {
            Label(platform: platform, version: version, build: build)
        }

        private static func validatePathComponent(_ value: String, field: String) throws {
            guard !value.isEmpty else {
                throw ValidationError.emptyComponent(field: field)
            }
            guard value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
                throw ValidationError.invalidPathComponent(field: field, value: value)
            }
        }
    }
}

public extension PrivateHeaderGeneration.Source {
    enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case emptyComponent(field: String)
        case invalidPathComponent(field: String, value: String)

        public var description: String {
            switch self {
            case .emptyComponent(let field):
                "\(field) must not be empty"
            case .invalidPathComponent(let field, let value):
                "\(field) is not safe as a path component: \(value)"
            }
        }
    }

    enum Platform: String, CaseIterable, Hashable, Sendable {
        case iOS = "iOS"
        case macOS = "macOS"

        public var displayName: String {
            rawValue
        }
    }

    struct Label: CustomStringConvertible, Hashable, Sendable {
        public let displayName: String
        public let directoryName: String

        init(platform: Platform, version: String, build: String?) {
            let baseName = "\(platform.displayName) \(version)"
            let directoryBaseName = "\(platform.displayName)\(version)"
            if let build {
                self.displayName = "\(baseName) (\(build))"
                self.directoryName = "\(directoryBaseName)(\(build))"
            } else {
                self.displayName = baseName
                self.directoryName = directoryBaseName
            }
        }

        public var description: String {
            displayName
        }
    }
}

public extension PrivateHeaderGeneration {
    struct Target: CustomStringConvertible, Hashable, Sendable {
        public static let allAvailable = Target(identifier: "allAvailable")

        private let identifier: String

        private init(identifier: String) {
            self.identifier = identifier
        }

        static func generated(identifier: String) -> Target {
            Target(identifier: identifier)
        }

        public var description: String {
            identifier
        }
    }
}

public extension PrivateHeaderGeneration {
    enum TargetRequest: Hashable, Sendable {
        case frameworks
        case system
        case allAvailable
        case identifiers([String])
        case query(String)
    }

    enum ResumeBehavior: Hashable, Sendable {
        case resume
        case fresh
        case requireExplicitResume(resumeRequested: Bool)
    }

    struct Options: Hashable, Sendable {
        public var layout: Layout
        public var targetRequest: TargetRequest
        public var systemRoot: URL?
        public var helperURLs: RawDumping.HelperURLs?
        public var executionMode: RawDumping.ExecutionMode?
        public var rawDumpingOptions: RawDumping.Options
        public var includeNestedChildren: Bool
        public var resumeBehavior: ResumeBehavior
        public var toolVersion: String
        public var outputBaseDirectory: URL?

        public init(
            layout: Layout = .headers,
            targetRequest: TargetRequest = .allAvailable,
            systemRoot: URL? = nil,
            helperURLs: RawDumping.HelperURLs? = nil,
            executionMode: RawDumping.ExecutionMode? = nil,
            rawDumpingOptions: RawDumping.Options = RawDumping.Options(),
            includeNestedChildren: Bool = true,
            resumeBehavior: ResumeBehavior = .requireExplicitResume(resumeRequested: false),
            toolVersion: String = "0.1.0",
            outputBaseDirectory: URL? = nil
        ) {
            self.layout = layout
            self.targetRequest = targetRequest
            self.systemRoot = systemRoot
            self.helperURLs = helperURLs
            self.executionMode = executionMode
            self.rawDumpingOptions = rawDumpingOptions
            self.includeNestedChildren = includeNestedChildren
            self.resumeBehavior = resumeBehavior
            self.toolVersion = toolVersion
            self.outputBaseDirectory = outputBaseDirectory
        }
    }

    struct Output: Hashable, Sendable {
        public let artifactBaseDirectory: URL
        public let stateBaseDirectory: URL

        public init(
            artifactBaseDirectory: URL,
            stateBaseDirectory: URL
        ) {
            self.artifactBaseDirectory = artifactBaseDirectory
            self.stateBaseDirectory = stateBaseDirectory
        }

        public init(baseDirectory: URL) {
            self.init(
                artifactBaseDirectory: baseDirectory,
                stateBaseDirectory: baseDirectory.appendingPathComponent(".state", isDirectory: true)
            )
        }
    }

    struct Plan: Hashable, Sendable {
        public let source: Source
        public let output: Output
        public let artifactDirectory: URL
        public let stateDirectory: URL
        public let target: Target
        public let options: Options

        public init(
            source: Source,
            output: Output,
            options: Options = Options()
        ) {
            let label = source.label
            self.source = source
            self.output = output
            self.artifactDirectory = output.artifactBaseDirectory.appendingPathComponent(
                label.directoryName,
                isDirectory: true
            )
            self.stateDirectory = output.stateBaseDirectory.appendingPathComponent(
                label.directoryName,
                isDirectory: true
            )
            self.target = .allAvailable
            self.options = options
        }
    }

    struct Result: Hashable, Sendable {
        public let plan: Plan
        public let artifactDirectory: URL
        public let generatedTargets: [Target]
        public let runID: String
        public let manifestURL: URL
        public let runRecordURL: URL

        init(
            plan: Plan,
            generatedTargets: [Target],
            runID: String,
            manifestURL: URL,
            runRecordURL: URL
        ) {
            self.plan = plan
            self.artifactDirectory = plan.artifactDirectory
            self.generatedTargets = generatedTargets
            self.runID = runID
            self.manifestURL = manifestURL
            self.runRecordURL = runRecordURL
        }
    }

    enum GenerationError: Error, Equatable, CustomStringConvertible, Sendable {
        case missingExecutionConfiguration(String)
        case noDiscoveredTargets(systemRoot: String)
        case unknownSelectedTargets([String])
        case unresolvedTargetQuery(String)
        case incompatibleResume([ResumeCompatibilityReason])
        case resumeRequired(ResumeSummary)
        case runFailed(runID: String, failedTargetIDs: [String])

        public var description: String {
            switch self {
            case .missingExecutionConfiguration(let field):
                "private header generation requires \(field)"
            case .noDiscoveredTargets(let systemRoot):
                "no private header targets were discovered under \(systemRoot)"
            case .unknownSelectedTargets(let targetIDs):
                "selected targets were not discovered: \(targetIDs.joined(separator: ", "))"
            case .unresolvedTargetQuery(let query):
                "target query could not be resolved: \(query)"
            case .incompatibleResume(let reasons):
                "existing generation state is incompatible: \(reasons)"
            case .resumeRequired(let summary):
                "existing generation state is unfinished; explicit resume is required for \(summary.latestRunID ?? "unknown run")"
            case .runFailed(let runID, let failedTargetIDs):
                "private header generation run \(runID) failed for \(failedTargetIDs.count) targets"
            }
        }
    }
}
