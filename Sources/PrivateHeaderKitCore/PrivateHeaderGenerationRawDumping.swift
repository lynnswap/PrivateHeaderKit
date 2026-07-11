import Foundation

extension PrivateHeaderGeneration {
  package enum RawDumping {
    package static let helperSubcommand = "__raw-dump"

    package static func makeInvocation(_ request: Request) -> Invocation {
      let helperURL = request.executionMode.helperURL(from: request.helperURLs)
      return Invocation(
        phaseLabel: "raw-header-dump",
        executionMode: request.executionMode,
        helperURL: helperURL,
        inputPath: request.inputPath,
        stagingOutputDirectory: request.stagingOutputDirectory,
        command: makeCommand(helperURL: helperURL, request: request),
        environment: makeEnvironment(for: request)
      )
    }

    private static func makeCommand(helperURL: URL, request: Request) -> [String] {
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
      if request.options.skipExisting { command.append("-s") }
      if request.options.useSharedCache { command.append("-c") }
      if request.options.verbose { command.append("-D") }
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
  package struct HelperURLs: Hashable, Sendable {
    package let host: URL
    package let simulator: URL

    package init(host: URL, simulator: URL) {
      self.host = host
      self.simulator = simulator
    }
  }

  package enum ExecutionMode: Hashable, Sendable {
    case host
    case simulator(deviceUDID: String, runtimeRoot: String)

    fileprivate var isHost: Bool {
      if case .host = self { return true }
      return false
    }

    fileprivate func helperURL(from helperURLs: HelperURLs) -> URL {
      switch self {
      case .host: helperURLs.host
      case .simulator: helperURLs.simulator
      }
    }
  }

  package struct Options: Hashable, Sendable {
    package var skipExisting: Bool
    package var useSharedCache: Bool
    package var verbose: Bool
    package var preferRuntimeMetadata: Bool
    package var helperEnvironment: [String: String]

    package init(
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

  package struct Request: Hashable, Sendable {
    package let helperURLs: HelperURLs
    package let executionMode: ExecutionMode
    package let inputPath: String
    package let stagingOutputDirectory: URL
    package let options: Options

    package init(
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

  package struct Invocation: Hashable, Sendable {
    package let phaseLabel: String
    package let executionMode: ExecutionMode
    package let helperURL: URL
    package let inputPath: String
    package let stagingOutputDirectory: URL
    package let command: [String]
    package let environment: [String: String]
  }

  package struct Result: Hashable, Sendable {
    package let terminationStatus: Int32
    package let wasKilled: Bool
    package let failureSummary: String?

    package init(
      terminationStatus: Int32,
      wasKilled: Bool = false,
      failureSummary: String? = nil
    ) {
      self.terminationStatus = terminationStatus
      self.wasKilled = wasKilled
      self.failureSummary = failureSummary
    }

    package var succeeded: Bool {
      terminationStatus == 0 && !wasKilled
    }
  }
}
