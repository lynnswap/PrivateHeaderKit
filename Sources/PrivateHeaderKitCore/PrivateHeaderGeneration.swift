import Foundation

package enum PrivateHeaderGeneration {
  package static func makePlan(
    source: Source,
    output: Output,
    options: Options = Options()
  ) -> Plan {
    Plan(source: source, output: output, options: options)
  }

  package static func generatePrivateHeaders(
    source: Source,
    output: Output,
    options: Options = Options(),
    rawDumpRunner: @escaping GenerationExecutor.RawDumpRunner,
    progressReporter: GenerationExecutor.ProgressReporter? = nil
  ) async throws -> Result {
    try await GenerationExecutor(rawDumpRunner: rawDumpRunner).run(
      GenerationExecutor.Configuration(
        plan: makePlan(source: source, output: output, options: options),
        progressReporter: progressReporter
      )
    )
  }
}

extension PrivateHeaderGeneration {
  package struct Source: Hashable, Sendable {
    package let platform: Platform
    package let version: String
    package let build: String?

    package init(platform: Platform, version: String, build: String? = nil) throws {
      try Self.validatePathComponent(version, field: "version")
      let build = build.flatMap { $0.isEmpty ? nil : $0 }
      if let build {
        try Self.validatePathComponent(build, field: "build")
      }
      self.platform = platform
      self.version = version
      self.build = build
    }

    package var label: Label {
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

    package enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
      case emptyComponent(field: String)
      case invalidPathComponent(field: String, value: String)

      package var description: String {
        switch self {
        case .emptyComponent(let field):
          "\(field) must not be empty"
        case .invalidPathComponent(let field, let value):
          "\(field) is not safe as a path component: \(value)"
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
      package let directoryName: String

      fileprivate init(platform: Platform, version: String, build: String?) {
        let baseName = "\(platform.displayName) \(version)"
        let directoryBaseName = "\(platform.displayName)\(version)"
        if let build {
          displayName = "\(baseName) (\(build))"
          directoryName = "\(directoryBaseName)(\(build))"
        } else {
          displayName = baseName
          directoryName = directoryBaseName
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
    package var toolVersion: String

    package init(
      layout: Layout = .headers,
      targetRequest: TargetRequest = .allAvailable,
      systemRoot: URL? = nil,
      helperURLs: RawDumping.HelperURLs? = nil,
      executionMode: RawDumping.ExecutionMode? = nil,
      rawDumpingOptions: RawDumping.Options = RawDumping.Options(),
      includeNestedChildren: Bool = true,
      resumeBehavior: ResumeBehavior = .requireExplicitResume(resumeRequested: false),
      toolVersion: String = "0.1.0"
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

    package init(source: Source, output: Output, options: Options = Options()) {
      let label = source.label
      self.source = source
      self.output = output
      artifactDirectory = output.artifactBaseDirectory.appendingPathComponent(
        label.directoryName,
        isDirectory: true
      )
      stateDirectory = output.stateBaseDirectory.appendingPathComponent(
        label.directoryName,
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
