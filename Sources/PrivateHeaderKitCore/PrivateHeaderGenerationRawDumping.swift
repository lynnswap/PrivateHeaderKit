import Foundation
import PrivateHeaderKitHelperProtocol

public extension PrivateHeaderGeneration {
    enum RawDumping {
        public static func makeInvocation(_ request: Request) -> Invocation {
            let helperURL = request.executionMode.helperURL(from: request.helperURLs)
            let command = makeCommand(
                helperURL: helperURL,
                request: request
            )
            let environment = makeEnvironment(for: request)

            return Invocation(
                phaseLabel: "raw-header-dump",
                executionMode: request.executionMode,
                helperURL: helperURL,
                inputPath: request.inputPath,
                stagingOutputDirectory: request.stagingOutputDirectory,
                command: command,
                environment: environment
            )
        }

        public static func makeSharedCacheInventoryInvocation(
            helperURLs: HelperURLs,
            executionMode: ExecutionMode,
            helperEnvironment: [String: String] = [:]
        ) -> SharedCacheInventoryInvocation {
            let helperURL = executionMode.helperURL(from: helperURLs)
            let commandPrefix: [String]
            switch executionMode {
            case .host:
                commandPrefix = [helperURL.path]
            case .simulator(let deviceUDID, _):
                commandPrefix = [
                    "xcrun",
                    "simctl",
                    "spawn",
                    deviceUDID,
                    helperURL.path,
                ]
            }
            return SharedCacheInventoryInvocation(
                phaseLabel: "shared-cache-inventory",
                executionMode: executionMode,
                helperURL: helperURL,
                command: commandPrefix + [PrivateHeaderKitHelperCommand.sharedCacheInventory.rawValue],
                environment: makeEnvironment(
                    helperEnvironment: helperEnvironment,
                    executionMode: executionMode
                )
            )
        }

        private static func makeCommand(
            helperURL: URL,
            request: Request
        ) -> [String] {
            var command: [String]
            switch request.executionMode {
            case .host:
                command = [
                    helperURL.path,
                    PrivateHeaderKitHelperCommand.rawDump.rawValue,
                    "-o",
                    request.stagingOutputDirectory.path,
                ]
            case .simulator(let deviceUDID, _):
                command = [
                    "xcrun",
                    "simctl",
                    "spawn",
                    deviceUDID,
                    helperURL.path,
                    PrivateHeaderKitHelperCommand.rawDump.rawValue,
                    "-o",
                    request.stagingOutputDirectory.path,
                ]
            }

            command += ["-b", "-h"]
            if request.options.skipExisting {
                command.append("-s")
            }
            if request.options.useSharedCache {
                command.append("-c")
                if let expectedCacheUUID = request.expectedCacheUUID {
                    command += ["--expected-cache-uuid", expectedCacheUUID.uuidString.lowercased()]
                }
            }
            if request.options.verbose {
                command.append("-D")
            }
            if request.executionMode.isHost, request.options.preferRuntimeMetadata {
                command.append("-R")
            }
            command.append(request.inputPath)
            return command
        }

        private static func makeEnvironment(for request: Request) -> [String: String] {
            makeEnvironment(
                helperEnvironment: request.options.helperEnvironment,
                executionMode: request.executionMode
            )
        }

        private static func makeEnvironment(
            helperEnvironment: [String: String],
            executionMode: ExecutionMode
        ) -> [String: String] {
            var environment = helperEnvironment

            if case .simulator(_, let runtimeRoot) = executionMode {
                environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"] = runtimeRoot
                environment["SIMCTL_CHILD_DYLD_ROOT_PATH"] = runtimeRoot
            }

            return environment
        }
    }
}

public extension PrivateHeaderGeneration.RawDumping {
    struct HelperURLs: Hashable, Sendable {
        public let host: URL
        public let simulator: URL

        public init(host: URL, simulator: URL) {
            self.host = host
            self.simulator = simulator
        }
    }

    enum ExecutionMode: Hashable, Sendable {
        case host
        case simulator(deviceUDID: String, runtimeRoot: String)

        fileprivate var isHost: Bool {
            if case .host = self {
                return true
            }
            return false
        }

        fileprivate func helperURL(from helperURLs: HelperURLs) -> URL {
            switch self {
            case .host:
                helperURLs.host
            case .simulator:
                helperURLs.simulator
            }
        }
    }

    struct Options: Hashable, Sendable {
        public var skipExisting: Bool
        public var useSharedCache: Bool
        public var verbose: Bool
        public var preferRuntimeMetadata: Bool
        public var helperEnvironment: [String: String]

        public init(
            skipExisting: Bool = false,
            useSharedCache: Bool = false,
            verbose: Bool = false,
            preferRuntimeMetadata: Bool = false,
            helperEnvironment: [String: String] = [:]
        ) {
            self.skipExisting = skipExisting
            self.useSharedCache = useSharedCache
            self.verbose = verbose
            self.preferRuntimeMetadata = preferRuntimeMetadata
            self.helperEnvironment = helperEnvironment
        }
    }

    struct Request: Hashable, Sendable {
        public let helperURLs: HelperURLs
        public let executionMode: ExecutionMode
        public let inputPath: String
        public let stagingOutputDirectory: URL
        public let options: Options
        public let expectedCacheUUID: UUID?

        public init(
            helperURLs: HelperURLs,
            executionMode: ExecutionMode,
            inputPath: String,
            stagingOutputDirectory: URL,
            options: Options = Options(),
            expectedCacheUUID: UUID? = nil
        ) throws {
            guard options.useSharedCache == (expectedCacheUUID != nil) else {
                if options.useSharedCache {
                    throw ValidationError.missingExpectedCacheUUID
                }
                throw ValidationError.unexpectedCacheUUID
            }
            self.helperURLs = helperURLs
            self.executionMode = executionMode
            self.inputPath = inputPath
            self.stagingOutputDirectory = stagingOutputDirectory
            self.options = options
            self.expectedCacheUUID = expectedCacheUUID
        }

        public enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
            case missingExpectedCacheUUID
            case unexpectedCacheUUID

            public var description: String {
                switch self {
                case .missingExpectedCacheUUID:
                    "shared-cache raw dumping requires the inventoried cache UUID"
                case .unexpectedCacheUUID:
                    "a cache UUID is invalid when shared-cache raw dumping is disabled"
                }
            }
        }
    }

    struct Invocation: Hashable, Sendable {
        public let phaseLabel: String
        public let executionMode: ExecutionMode
        public let helperURL: URL
        public let inputPath: String
        public let stagingOutputDirectory: URL
        public let command: [String]
        public let environment: [String: String]
    }

    struct SharedCacheInventoryInvocation: Hashable, Sendable {
        public let phaseLabel: String
        public let executionMode: ExecutionMode
        public let helperURL: URL
        public let command: [String]
        public let environment: [String: String]
    }

    enum SharedCacheInventoryRunnerError: Error, Equatable, CustomStringConvertible, Sendable {
        case exited(status: Int32, output: String?)
        case terminatedBySignal(signal: Int32, output: String?)

        public var description: String {
            switch self {
            case .exited(let status, let output):
                Self.message("shared-cache inventory exited with status \(status)", output: output)
            case .terminatedBySignal(let signal, let output):
                Self.message("shared-cache inventory terminated by signal \(signal)", output: output)
            }
        }

        private static func message(_ prefix: String, output: String?) -> String {
            guard let output, !output.isEmpty else {
                return prefix
            }
            return "\(prefix)\n\(output)"
        }
    }

    struct Result: Hashable, Sendable {
        public let terminationStatus: Int32
        public let wasKilled: Bool
        public let failureSummary: String?

        public init(
            terminationStatus: Int32,
            wasKilled: Bool = false,
            failureSummary: String? = nil
        ) {
            self.terminationStatus = terminationStatus
            self.wasKilled = wasKilled
            self.failureSummary = failureSummary
        }

        public var succeeded: Bool {
            terminationStatus == 0 && !wasKilled
        }
    }
}
