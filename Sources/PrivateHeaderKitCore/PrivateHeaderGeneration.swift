import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum PrivateHeaderGeneration {
  package static func makePlan(
    source: Source,
    output: Output,
    options: Options
  ) -> Plan {
    Plan(source: source, output: output, options: options)
  }
}

extension PrivateHeaderGeneration {
  package struct Source: Hashable, Sendable {
    package let platform: Platform
    package let version: String
    package let build: String?

    package init(platform: Platform, version: String, build: String? = nil) throws {
      let version = version.precomposedStringWithCanonicalMapping
      guard !version.isEmpty else {
        throw ValidationError.emptyComponent(field: "version")
      }
      let build = build
        .map(\.precomposedStringWithCanonicalMapping)
        .flatMap { $0.isEmpty ? nil : $0 }
      let storageIdentifier = Self.makeStorageIdentifier(
        platform: platform,
        version: version,
        build: build
      )
      guard storageIdentifier.utf8.count <= Int(NAME_MAX) else {
        throw ValidationError.storageIdentifierTooLong(
          actualUTF8Count: storageIdentifier.utf8.count,
          maximumUTF8Count: Int(NAME_MAX)
        )
      }
      self.platform = platform
      self.version = version
      self.build = build
    }

    package var label: Label {
      Label(platform: platform, version: version, build: build)
    }

    package var storageIdentifier: String {
      Self.makeStorageIdentifier(platform: platform, version: version, build: build)
    }

    private static func makeStorageIdentifier(
      platform: Platform,
      version: String,
      build: String?
    ) -> String {
      let platformName: String
      switch platform {
      case .iOS:
        platformName = "ios"
      case .macOS:
        platformName = "macos"
      }

      let version = encodeStorageField(version)
      guard let build else {
        return "\(platformName)-v1-\(version)-b0"
      }
      return "\(platformName)-v1-\(version)-b1-\(encodeStorageField(build))"
    }

    private static func encodeStorageField(_ value: String) -> String {
      let hexDigits = Array("0123456789abcdef")
      var result = ""
      result.reserveCapacity(value.utf8.count * 3)
      for byte in value.utf8 {
        switch byte {
        case 0x2e:
          result.append(".")
        case 0x30...0x39:
          result.append(hexDigits[Int(byte) - 0x30])
        default:
          result.append("~")
          result.append(hexDigits[Int(byte >> 4)])
          result.append(hexDigits[Int(byte & 0x0f)])
        }
      }
      return result
    }

    package enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
      case emptyComponent(field: String)
      case storageIdentifierTooLong(actualUTF8Count: Int, maximumUTF8Count: Int)

      package var description: String {
        switch self {
        case .emptyComponent(let field):
          "\(field) must not be empty"
        case .storageIdentifierTooLong(let actualUTF8Count, let maximumUTF8Count):
          "source storage identifier is \(actualUTF8Count) UTF-8 bytes; "
            + "the maximum is \(maximumUTF8Count)"
        }
      }
    }

    package enum Platform: String, Codable, CaseIterable, Hashable, Sendable {
      case iOS = "iOS"
      case macOS = "macOS"

      package var displayName: String { rawValue }
    }

    package struct Label: CustomStringConvertible, Hashable, Sendable {
      package let displayName: String

      fileprivate init(platform: Platform, version: String, build: String?) {
        let baseName = "\(platform.displayName) \(version)"
        if let build {
          displayName = "\(baseName) (\(build))"
        } else {
          displayName = baseName
        }
      }

      package var description: String { displayName }
    }
  }

  package struct Target: CustomStringConvertible, Hashable, Sendable {
    package static let allAvailable = Target(identifier: "allAvailable")
    package let identifier: String

    fileprivate init(identifier: String) {
      self.identifier = identifier
    }

    package static func generated(identifier: String) -> Target {
      Target(identifier: identifier)
    }

    package var description: String { identifier }
  }

  package enum ProgressEvent: Equatable, Sendable {
    case runStarted(runID: RunID, totalTargetCount: Int)
    case targetStarted(index: Int, total: Int, displayName: String)
    case targetFinished(index: Int, total: Int, displayName: String, status: RunTargetStatus)
    case warning(GenerationWarning)
    case runFinished(RunSummary)
  }

  package struct GenerationWarning: Hashable, Sendable {
    package let kind: String
    package let relativePath: String
    package let message: String

    package init(kind: String, relativePath: String, message: String) {
      self.kind = kind
      self.relativePath = relativePath
      self.message = message
    }
  }

  package struct RunSummary: Hashable, Sendable {
    package let runID: RunID
    package let status: RunStatus
    package let targetCounts: TargetCounts
    package let artifactDirectory: URL
    package let stateDatabaseURL: URL
    package let warnings: [GenerationWarning]

    package init(
      runID: RunID,
      status: RunStatus,
      targetCounts: TargetCounts,
      artifactDirectory: URL,
      stateDatabaseURL: URL,
      warnings: [GenerationWarning] = []
    ) {
      self.runID = runID
      self.status = status
      self.targetCounts = targetCounts
      self.artifactDirectory = artifactDirectory
      self.stateDatabaseURL = stateDatabaseURL
      self.warnings = warnings
    }
  }

  package struct RunFailure: Equatable, Sendable {
    package let summary: RunSummary
    package let failedTargetIDs: [String]

    package init(summary: RunSummary, failedTargetIDs: [String]) {
      self.summary = summary
      self.failedTargetIDs = failedTargetIDs
    }
  }

  package struct RunInterruption: Equatable, Sendable {
    package let summary: RunSummary

    package init(summary: RunSummary) {
      self.summary = summary
    }
  }

  package struct RunInfrastructureFailure: Equatable, Sendable {
    package let summary: RunSummary
    package let message: String

    package init(summary: RunSummary, message: String) {
      self.summary = summary
      self.message = message
    }
  }

  package enum TargetRequest: Hashable, Sendable {
    case frameworks
    case system
    case allAvailable
    case identifiers([String])
    case query(String)
  }

  package enum ResumeBehavior: Hashable, Sendable {
    case resume
    case fresh
    case requireExplicitResume(resumeRequested: Bool)
  }

  package struct Options: Hashable, Sendable {
    package var layout: Layout
    package var targetRequest: TargetRequest
    package var systemRoot: URL?
    package var helperURLs: RawDumping.HelperURLs?
    package var executionMode: RawDumping.ExecutionMode?
    package var rawDumpingOptions: RawDumping.Options
    package var includeNestedChildren: Bool
    package var resumeBehavior: ResumeBehavior
    package var toolCompatibilityIdentity: String

    package init(
      layout: Layout = .headers,
      targetRequest: TargetRequest = .allAvailable,
      systemRoot: URL? = nil,
      helperURLs: RawDumping.HelperURLs? = nil,
      executionMode: RawDumping.ExecutionMode? = nil,
      rawDumpingOptions: RawDumping.Options = RawDumping.Options(),
      includeNestedChildren: Bool = true,
      resumeBehavior: ResumeBehavior = .requireExplicitResume(resumeRequested: false),
      toolCompatibilityIdentity: String
    ) {
      self.layout = layout
      self.targetRequest = targetRequest
      self.systemRoot = systemRoot
      self.helperURLs = helperURLs
      self.executionMode = executionMode
      self.rawDumpingOptions = rawDumpingOptions
      self.includeNestedChildren = includeNestedChildren
      self.resumeBehavior = resumeBehavior
      self.toolCompatibilityIdentity = toolCompatibilityIdentity
    }
  }

  package struct Output: Hashable, Sendable {
    package let baseDirectory: URL

    package init(baseDirectory: URL) {
      self.baseDirectory = baseDirectory
    }

    package var artifactBaseDirectory: URL { baseDirectory }
    package var stateBaseDirectory: URL {
      baseDirectory.appendingPathComponent(".state", isDirectory: true)
    }
  }

  package struct Plan: Hashable, Sendable {
    package let source: Source
    package let output: Output
    package let artifactDirectory: URL
    package let stateDirectory: URL
    package let target: Target
    package let options: Options

    package init(source: Source, output: Output, options: Options) {
      self.source = source
      self.output = output
      artifactDirectory = output.artifactBaseDirectory.appendingPathComponent(
        source.storageIdentifier,
        isDirectory: true
      )
      stateDirectory = output.stateBaseDirectory.appendingPathComponent(
        source.storageIdentifier,
        isDirectory: true
      )
      target = .allAvailable
      self.options = options
    }

    package var databaseURL: URL {
      stateDirectory.appendingPathComponent("generation.sqlite", isDirectory: false)
    }
  }

  package struct Result: Hashable, Sendable {
    package let plan: Plan
    package let artifactDirectory: URL
    package let generatedTargets: [Target]
    package let runID: RunID
    package let stateDatabaseURL: URL
    package let targetCounts: TargetCounts
    package let warnings: [GenerationWarning]

    package init(
      plan: Plan,
      artifactDirectory: URL,
      generatedTargets: [Target],
      runID: RunID,
      stateDatabaseURL: URL,
      targetCounts: TargetCounts,
      warnings: [GenerationWarning] = []
    ) {
      self.plan = plan
      self.artifactDirectory = artifactDirectory
      self.generatedTargets = generatedTargets
      self.runID = runID
      self.stateDatabaseURL = stateDatabaseURL
      self.targetCounts = targetCounts
      self.warnings = warnings
    }

    package var summary: RunSummary {
      RunSummary(
        runID: runID,
        status: .completed,
        targetCounts: targetCounts,
        artifactDirectory: artifactDirectory,
        stateDatabaseURL: stateDatabaseURL,
        warnings: warnings
      )
    }
  }

  package enum GenerationError: Error, Equatable, CustomStringConvertible, Sendable {
    case missingExecutionConfiguration(String)
    case emptySharedCacheInventory(cacheUUID: UUID)
    case sharedCacheCohortChanged(
      expectedUUID: UUID,
      expectedImagePathDigest: String,
      actualUUID: UUID,
      actualImagePathDigest: String
    )
    case noDiscoveredTargets(systemRoot: String)
    case unknownSelectedTargets([String])
    case unresolvedTargetQuery(String)
    case incompatibleResume(String)
    case resumeRequired(ResumeSummary)
    case legacyStateRequiresFresh(path: String)
    case legacyArtifactsRequireFresh(path: String)
    case runFailed(RunFailure)
    case runInterrupted(RunInterruption)
    case infrastructureFailed(RunInfrastructureFailure)

    package var description: String {
      switch self {
      case .missingExecutionConfiguration(let field):
        "private header generation requires \(field)"
      case .emptySharedCacheInventory(let cacheUUID):
        "loaded shared cache \(cacheUUID.uuidString.lowercased()) contains no images"
      case .sharedCacheCohortChanged(
        let expectedUUID,
        let expectedImagePathDigest,
        let actualUUID,
        let actualImagePathDigest
      ):
        "loaded shared cache changed after target preparation "
          + "(expected \(expectedUUID.uuidString.lowercased())/\(expectedImagePathDigest), "
          + "actual \(actualUUID.uuidString.lowercased())/\(actualImagePathDigest))"
      case .noDiscoveredTargets(let systemRoot):
        "no private header targets were discovered under \(systemRoot)"
      case .unknownSelectedTargets(let targetIDs):
        "selected targets were not discovered: \(targetIDs.joined(separator: ", "))"
      case .unresolvedTargetQuery(let query):
        "target query could not be resolved: \(query)"
      case .incompatibleResume(let reason):
        "existing generation state is incompatible: \(reason)"
      case .resumeRequired(let summary):
        "existing generation state is unfinished; explicit resume is required for \(summary.latestRunID.rawValue)"
      case .legacyStateRequiresFresh(let path):
        "legacy JSON state at \(path) requires an explicit fresh migration"
      case .legacyArtifactsRequireFresh(let path):
        "legacy artifact directory at \(path) requires an explicit fresh migration"
      case .runFailed(let failure):
        "private header generation run \(failure.summary.runID.rawValue) failed for \(failure.failedTargetIDs.count) targets"
      case .runInterrupted(let interruption):
        "private header generation run \(interruption.summary.runID.rawValue) was interrupted"
      case .infrastructureFailed(let failure):
        "private header generation run \(failure.summary.runID.rawValue) stopped after an infrastructure failure: \(failure.message)"
      }
    }
  }
}
