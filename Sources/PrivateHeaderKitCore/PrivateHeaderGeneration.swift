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
        throw GenerationError.notImplemented(
            plan: makePlan(
                source: source,
                output: output,
                options: options
            )
        )
    }
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

        public var description: String {
            identifier
        }
    }
}

public extension PrivateHeaderGeneration {
    struct Options: Hashable, Sendable {
        public init() {}
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

        init(plan: Plan, generatedTargets: [Target]) {
            self.plan = plan
            self.artifactDirectory = plan.artifactDirectory
            self.generatedTargets = generatedTargets
        }
    }

    enum GenerationError: Error, Equatable, CustomStringConvertible, Sendable {
        case notImplemented(plan: Plan)

        public var description: String {
            switch self {
            case .notImplemented(let plan):
                "private header generation is not implemented for \(plan.source.label.displayName)"
            }
        }
    }
}
