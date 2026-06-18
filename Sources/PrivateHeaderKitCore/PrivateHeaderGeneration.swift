import Foundation

public enum PrivateHeaderGeneration {
    public static func makePlan(
        source: Source,
        artifactRootDirectory: URL,
        options: Options = Options()
    ) -> Plan {
        Plan(
            source: source,
            artifactRootDirectory: artifactRootDirectory,
            options: options
        )
    }

    public static func generatePrivateHeaders(
        source: Source,
        artifactRootDirectory: URL,
        options: Options = Options()
    ) async throws -> Result {
        throw GenerationError.notImplemented(
            plan: makePlan(
                source: source,
                artifactRootDirectory: artifactRootDirectory,
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

        public init(platform: Platform, version: String, build: String? = nil) {
            self.platform = platform
            self.version = version
            self.build = build.flatMap { $0.isEmpty ? nil : $0 }
        }

        public var label: Label {
            Label(platform: platform, version: version, build: build)
        }
    }
}

public extension PrivateHeaderGeneration.Source {
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

    struct Plan: Hashable, Sendable {
        public let source: Source
        public let artifactRootDirectory: URL
        public let artifactDirectory: URL
        public let stateDirectory: URL
        public let target: Target
        public let options: Options

        public init(
            source: Source,
            artifactRootDirectory: URL,
            options: Options = Options()
        ) {
            let label = source.label
            self.source = source
            self.artifactRootDirectory = artifactRootDirectory
            self.artifactDirectory = artifactRootDirectory.appendingPathComponent(
                label.directoryName,
                isDirectory: true
            )
            self.stateDirectory = artifactRootDirectory
                .appendingPathComponent(".state", isDirectory: true)
                .appendingPathComponent(label.directoryName, isDirectory: true)
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
