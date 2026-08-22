import Foundation
import PrivateHeaderKitHelperProtocol

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
    package let releaseChannel: ReleaseChannel

    private struct NormalizedIdentity {
      let version: String
      let build: String?
    }

    package init(
      platform: Platform,
      version: String,
      build: String? = nil,
      metadataIsSeed: Bool
    ) throws {
      let identity = try Self.normalizedIdentity(
        platform: platform,
        version: version,
        build: build
      )
      let releaseChannel: ReleaseChannel = metadataIsSeed ? .beta : .release
      guard releaseChannel != .beta || identity.build != nil else {
        throw ValidationError.seedBuildMissing
      }
      let artifactDirectoryName = Self.makeArtifactDirectoryName(
        version: identity.version,
        build: identity.build,
        releaseChannel: releaseChannel
      )
      guard artifactDirectoryName.utf8.count <= Int(NAME_MAX) else {
        throw ValidationError.artifactDirectoryNameTooLong(
          actualUTF8Count: artifactDirectoryName.utf8.count,
          maximumUTF8Count: Int(NAME_MAX)
        )
      }
      self.platform = platform
      self.version = identity.version
      self.build = identity.build
      self.releaseChannel = releaseChannel
    }

    package static func validateIdentity(
      platform: Platform,
      version: String,
      build: String?
    ) throws {
      _ = try normalizedIdentity(
        platform: platform,
        version: version,
        build: build
      )
    }

    package static func versionAndBuildDisplayName(
      version: String,
      build: String?,
      releaseChannel: ReleaseChannel
    ) -> String {
      let normalizedVersion = version.precomposedStringWithCanonicalMapping
      let normalizedBuild =
        build
        .map(\.precomposedStringWithCanonicalMapping)
        .flatMap { $0.isEmpty ? nil : $0 }
      var name = normalizedVersion
      if releaseChannel == .beta {
        name += " beta"
      }
      if let normalizedBuild {
        name += " (\(normalizedBuild))"
      }
      return name
    }

    package var label: Label {
      Label(
        platform: platform,
        version: version,
        build: build,
        releaseChannel: releaseChannel
      )
    }

    package var storageIdentifier: String {
      Self.makeStorageIdentifier(platform: platform, version: version, build: build)
    }

    package var artifactDirectoryName: String {
      Self.makeArtifactDirectoryName(
        version: version,
        build: build,
        releaseChannel: releaseChannel
      )
    }

    private static func normalizedIdentity(
      platform: Platform,
      version: String,
      build: String?
    ) throws -> NormalizedIdentity {
      let version = version.precomposedStringWithCanonicalMapping
      guard !version.isEmpty else {
        throw ValidationError.emptyComponent(field: "version")
      }
      let build =
        build
        .map(\.precomposedStringWithCanonicalMapping)
        .flatMap { $0.isEmpty ? nil : $0 }
      let storageIdentifier = makeStorageIdentifier(
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
      return NormalizedIdentity(version: version, build: build)
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
      case .watchOS:
        platformName = "watchos"
      }

      let version = encodeStorageField(version)
      guard let build else {
        return "\(platformName)-v1-\(version)-b0"
      }
      return "\(platformName)-v1-\(version)-b1-\(encodeStorageField(build))"
    }

    private static func makeArtifactDirectoryName(
      version: String,
      build: String?,
      releaseChannel: ReleaseChannel
    ) -> String {
      var components = [
        isHumanReadableVersion(version) ? version : encodeArtifactField(version)
      ]
      if releaseChannel == .beta {
        components.append("beta")
      }
      if let build {
        components.append(
          isHumanReadableBuild(build) ? build : encodeArtifactField(build)
        )
      }
      return components.joined(separator: "_")
    }

    private static func isHumanReadableVersion(_ value: String) -> Bool {
      guard value != ".", value != ".." else { return false }
      return value.utf8.allSatisfy { byte in
        byte == 0x2e || (0x30...0x39).contains(byte)
      }
    }

    private static func isHumanReadableBuild(_ value: String) -> Bool {
      let bytes = Array(value.utf8)
      var index = bytes.startIndex
      while index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) {
        index += 1
      }
      guard index > bytes.startIndex,
        index < bytes.endIndex,
        (0x41...0x5a).contains(bytes[index])
      else {
        return false
      }
      index += 1
      let digitStart = index
      while index < bytes.endIndex, (0x30...0x39).contains(bytes[index]) {
        index += 1
      }
      guard index > digitStart else { return false }
      return bytes[index...].allSatisfy { (0x61...0x7a).contains($0) }
    }

    private static func encodeArtifactField(_ value: String) -> String {
      let hexDigits = Array("0123456789abcdef")
      var result = ""
      result.reserveCapacity(value.utf8.count * 3)
      for byte in value.utf8 {
        if (0x30...0x39).contains(byte) {
          result.append(hexDigits[Int(byte) - 0x30])
        } else {
          result.append("~")
          result.append(hexDigits[Int(byte >> 4)])
          result.append(hexDigits[Int(byte & 0x0f)])
        }
      }
      return result
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
      case artifactDirectoryNameTooLong(actualUTF8Count: Int, maximumUTF8Count: Int)
      case seedBuildMissing

      package var description: String {
        switch self {
        case .emptyComponent(let field):
          "\(field) must not be empty"
        case .storageIdentifierTooLong(let actualUTF8Count, let maximumUTF8Count):
          "source storage identifier is \(actualUTF8Count) UTF-8 bytes; "
            + "the maximum is \(maximumUTF8Count)"
        case .artifactDirectoryNameTooLong(let actualUTF8Count, let maximumUTF8Count):
          "source artifact directory name is \(actualUTF8Count) UTF-8 bytes; "
            + "the maximum is \(maximumUTF8Count)"
        case .seedBuildMissing:
          "source build is required for a seed runtime"
        }
      }
    }

    package enum ReleaseChannel: String, Hashable, Sendable {
      case release
      case beta
    }

    package enum Platform: String, Codable, CaseIterable, Hashable, Sendable {
      case iOS = "iOS"
      case macOS = "macOS"
      case watchOS = "watchOS"

      package var displayName: String { rawValue }

      package var directoryName: String { rawValue }
    }

    package struct Label: CustomStringConvertible, Hashable, Sendable {
      package let displayName: String

      fileprivate init(
        platform: Platform,
        version: String,
        build: String?,
        releaseChannel: ReleaseChannel
      ) {
        displayName = "\(platform.displayName) "
          + Source.versionAndBuildDisplayName(
            version: version,
            build: build,
            releaseChannel: releaseChannel
          )
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
    case targetFinished(
      index: Int,
      total: Int,
      displayName: String,
      status: RunTargetStatus,
      failureSummary: String?
    )
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
    package let targetFailures: [TargetFailure]

    package init(
      runID: RunID,
      status: RunStatus,
      targetCounts: TargetCounts,
      artifactDirectory: URL,
      stateDatabaseURL: URL,
      warnings: [GenerationWarning] = [],
      targetFailures: [TargetFailure] = []
    ) {
      self.runID = runID
      self.status = status
      self.targetCounts = targetCounts
      self.artifactDirectory = artifactDirectory
      self.stateDatabaseURL = stateDatabaseURL
      self.warnings = warnings
      self.targetFailures = targetFailures
    }
  }

  package struct TargetFailure: Hashable, Sendable {
    package let targetID: String
    package let displayName: String
    package let status: RunTargetStatus
    package let message: String?

    package init(
      targetID: String,
      displayName: String,
      status: RunTargetStatus,
      message: String?
    ) {
      self.targetID = targetID
      self.displayName = displayName
      self.status = status
      self.message = message
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
    package var producerVersion: String

    package init(
      layout: Layout = .headers,
      targetRequest: TargetRequest = .allAvailable,
      systemRoot: URL? = nil,
      helperURLs: RawDumping.HelperURLs? = nil,
      executionMode: RawDumping.ExecutionMode? = nil,
      rawDumpingOptions: RawDumping.Options = RawDumping.Options(),
      includeNestedChildren: Bool = true,
      resumeBehavior: ResumeBehavior = .requireExplicitResume(resumeRequested: false),
      producerVersion: String = PrivateHeaderKitBuildInfo.version
    ) {
      self.layout = layout
      self.targetRequest = targetRequest
      self.systemRoot = systemRoot
      self.helperURLs = helperURLs
      self.executionMode = executionMode
      self.rawDumpingOptions = rawDumpingOptions
      self.includeNestedChildren = includeNestedChildren
      self.resumeBehavior = resumeBehavior
      self.producerVersion = producerVersion
    }
  }

  package struct Output: Hashable, Sendable {
    package let baseDirectory: URL

    package init(baseDirectory: URL) {
      self.baseDirectory = baseDirectory
    }

    package var artifactBaseDirectory: URL {
      baseDirectory.appendingPathComponent("generated-headers", isDirectory: true)
    }
    package var stateBaseDirectory: URL {
      baseDirectory.appendingPathComponent(".state", isDirectory: true)
    }

    package func artifactDirectory(for source: Source) -> URL {
      artifactBaseDirectory
        .appendingPathComponent(source.platform.directoryName, isDirectory: true)
        .appendingPathComponent(source.artifactDirectoryName, isDirectory: true)
    }

    package func legacyStorageArtifactDirectory(for source: Source) -> URL {
      artifactBaseDirectory.appendingPathComponent(
        source.storageIdentifier,
        isDirectory: true
      )
    }

    package func stateDirectory(for source: Source) -> URL {
      stateBaseDirectory.appendingPathComponent(source.storageIdentifier, isDirectory: true)
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
      artifactDirectory = output.artifactDirectory(for: source)
      stateDirectory = output.stateDirectory(for: source)
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
    case producerVersionMismatch(expected: String, actual: String)
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
    case legacyMigrationRequiresFresh(LegacyMigrationRequirement)
    case conflictingArtifactDirectories(legacyPath: String, currentPath: String)
    case runFailed(RunFailure)
    case runInterrupted(RunInterruption)
    case infrastructureFailed(RunInfrastructureFailure)

    package var description: String {
      switch self {
      case .missingExecutionConfiguration(let field):
        "private header generation requires \(field)"
      case .producerVersionMismatch(let expected, let actual):
        "private header helper version mismatch (expected \(expected), actual \(actual))"
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
      case .legacyMigrationRequiresFresh(let requirement):
        switch requirement {
        case .state(let path):
          "legacy JSON state at \(path) requires an explicit fresh migration"
        case .artifacts(let path):
          "legacy artifact directory at \(path) requires an explicit fresh migration"
        case .stateAndArtifacts(let statePath, let artifactsPath):
          "legacy JSON state at \(statePath) and artifact directory at \(artifactsPath) "
            + "require an explicit fresh migration"
        }
      case .conflictingArtifactDirectories(let legacyPath, let currentPath):
        "both the legacy and current generated-header directories exist "
          + "(legacy: \(legacyPath), current: \(currentPath)); "
          + "move one directory aside before retrying"
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
