import Foundation

extension PrivateHeaderGeneration {
    enum RawDumping {
        static let helperSubcommand = "__raw-dump"

        static func makeInvocation(_ request: Request) -> Invocation {
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

        private static func makeCommand(
            helperURL: URL,
            request: Request
        ) -> [String] {
            var command: [String]
            switch request.executionMode {
            case .host:
                command = [
                    helperURL.path,
                    helperSubcommand,
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
                    helperSubcommand,
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
            var environment = request.options.helperEnvironment

            if case .simulator(_, let runtimeRoot) = request.executionMode {
                environment["SIMCTL_CHILD_PH_RUNTIME_ROOT"] = runtimeRoot
                environment["SIMCTL_CHILD_DYLD_ROOT_PATH"] = runtimeRoot
            }

            return environment
        }
    }
}

extension PrivateHeaderGeneration.RawDumping {
    struct HelperURLs: Hashable, Sendable {
        let host: URL
        let simulator: URL

        init(host: URL, simulator: URL) {
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
        var skipExisting: Bool
        var useSharedCache: Bool
        var verbose: Bool
        var preferRuntimeMetadata: Bool
        var helperEnvironment: [String: String]

        init(
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
        let helperURLs: HelperURLs
        let executionMode: ExecutionMode
        let inputPath: String
        let stagingOutputDirectory: URL
        let options: Options

        init(
            helperURLs: HelperURLs,
            executionMode: ExecutionMode,
            inputPath: String,
            stagingOutputDirectory: URL,
            options: Options = Options()
        ) {
            self.helperURLs = helperURLs
            self.executionMode = executionMode
            self.inputPath = inputPath
            self.stagingOutputDirectory = stagingOutputDirectory
            self.options = options
        }
    }

    struct Invocation: Hashable, Sendable {
        let phaseLabel: String
        let executionMode: ExecutionMode
        let helperURL: URL
        let inputPath: String
        let stagingOutputDirectory: URL
        let command: [String]
        let environment: [String: String]
    }
}
