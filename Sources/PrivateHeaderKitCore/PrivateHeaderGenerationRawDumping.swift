import Foundation
import PrivateHeaderKitHelperProtocol

extension PrivateHeaderGeneration {
  package enum RawDumping {
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

    package static func makeSharedCacheInventoryInvocation(
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

    private static func makeCommand(helperURL: URL, request: Request) -> [String] {
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
      if request.options.skipExisting { command.append("-s") }
      if case .expected(let expectedCacheUUID) = request.cacheSelection {
        command += [
          "-c",
          "--expected-cache-uuid",
          expectedCacheUUID.uuidString.lowercased(),
        ]
      }
      if request.options.verbose { command.append("-D") }
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
    fileprivate enum CacheSelection: Hashable, Sendable {
      case disabled
      case expected(UUID)
    }

    package let helperURLs: HelperURLs
    package let executionMode: ExecutionMode
    package let inputPath: String
    package let stagingOutputDirectory: URL
    package let options: Options
    fileprivate let cacheSelection: CacheSelection

    package var expectedCacheUUID: UUID? {
      guard case .expected(let cacheUUID) = cacheSelection else { return nil }
      return cacheUUID
    }

    package init(
      helperURLs: HelperURLs,
      executionMode: ExecutionMode,
      inputPath: String,
      stagingOutputDirectory: URL,
      options: Options = Options(),
      expectedCacheUUID: UUID? = nil
    ) throws {
      let cacheSelection: CacheSelection
      switch (options.useSharedCache, expectedCacheUUID) {
      case (true, .some(let cacheUUID)):
        cacheSelection = .expected(cacheUUID)
      case (false, .none):
        cacheSelection = .disabled
      case (true, .none):
        throw ValidationError.missingExpectedCacheUUID
      case (false, .some):
        throw ValidationError.unexpectedCacheUUID
      }
      self.helperURLs = helperURLs
      self.executionMode = executionMode
      self.inputPath = inputPath
      self.stagingOutputDirectory = stagingOutputDirectory
      self.options = options
      self.cacheSelection = cacheSelection
    }

    package enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
      case missingExpectedCacheUUID
      case unexpectedCacheUUID

      package var description: String {
        switch self {
        case .missingExpectedCacheUUID:
          "shared-cache raw dumping requires the inventoried cache UUID"
        case .unexpectedCacheUUID:
          "a cache UUID is invalid when shared-cache raw dumping is disabled"
        }
      }
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

  package struct SharedCacheInventoryInvocation: Hashable, Sendable {
    package let phaseLabel: String
    package let executionMode: ExecutionMode
    package let helperURL: URL
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
