import Foundation

extension PrivateHeaderGeneration.GenerationExecutor {
  struct StagedArtifacts {
    /// Published path of each staged file.
    let files: [PrivateHeaderGeneration.ArtifactPath: URL]
  }

  /// Finds the headers, Swift interfaces, and symbol lists a helper wrote for a target.
  static func collectStagedArtifacts(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    in targetStagingDirectory: URL,
    runtimeRoot: String,
    artifactRoot: PrivateHeaderGeneration.ArtifactPath,
    includesAnalysisBinary: Bool = false
  ) throws -> StagedArtifacts {
    let candidates = stagedSourceDirectoryCandidates(
      for: target,
      in: targetStagingDirectory,
      runtimeRoot: runtimeRoot
    )
    for candidate in candidates {
      let files = try artifactFiles(
        under: candidate,
        artifactRoot: artifactRoot,
        includesAnalysisBinary: includesAnalysisBinary
      )
      if !files.isEmpty {
        return StagedArtifacts(files: files)
      }
    }
    return StagedArtifacts(files: [:])
  }

  fileprivate static func artifactFiles(
    under sourceDirectory: URL,
    artifactRoot: PrivateHeaderGeneration.ArtifactPath,
    includesAnalysisBinary: Bool
  ) throws -> [PrivateHeaderGeneration.ArtifactPath: URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [:] }

    var enumerationError: (any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: sourceDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else { return [:] }

    let sourcePath = sourceDirectory.standardizedFileURL.path
    var result: [PrivateHeaderGeneration.ArtifactPath: URL] = [:]
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      let relative = String(url.standardizedFileURL.path.dropFirst(sourcePath.count + 1))
      guard ["h", "swiftinterface", "tsv"].contains(url.pathExtension)
        || (includesAnalysisBinary && relative == "Analysis/Executable.macho")
      else { continue }
      result[try PrivateHeaderGeneration.ArtifactPath(artifactRoot.rawValue + "/" + relative)] = url
    }
    if let enumerationError { throw enumerationError }
    return result
  }

  static func stagedSourceDirectoryCandidates(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    in targetStagingDirectory: URL,
    runtimeRoot: String
  ) -> [URL] {
    let runtimeInputPath = target.runtimeInputPath
    if case .application(let logicalImagePath) = target.source {
      let bundlePath = URL(fileURLWithPath: logicalImagePath).deletingLastPathComponent().path
      return [appendRelativePath(String(bundlePath.dropFirst()) + "/Headers", to: targetStagingDirectory)]
    }
    let trimmed = runtimeInputPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if runtimeInputPath.hasPrefix("/usr/lib/") {
      let name = URL(fileURLWithPath: runtimeInputPath).lastPathComponent
      return stageUsrLibRoots(stageDirectory: targetStagingDirectory, runtimeRoot: runtimeRoot)
        .map { $0.appendingPathComponent(name, isDirectory: true) }
    }
    let relative = String(runtimeInputPath.dropFirst("/System/Library/".count))
    var candidates = stageSystemLibraryRoots(
      stageDirectory: targetStagingDirectory,
      runtimeRoot: runtimeRoot
    ).map { appendRelativePath(relative, to: $0) }
    candidates.append(appendRelativePath(trimmed, to: targetStagingDirectory))
    return candidates
  }

  static func artifactRoot(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    layout: PrivateHeaderGeneration.Layout
  ) throws -> PrivateHeaderGeneration.ArtifactPath {
    switch layout {
    case .headers:
      target.artifactRoot
    case .bundle:
      try bundleArtifactRoot(for: target.source)
    }
  }

  fileprivate static func bundleArtifactRoot(
    for source: PrivateHeaderGeneration.TargetDiscovery.SourceMetadata
  ) throws -> PrivateHeaderGeneration.ArtifactPath {
    switch source {
    case .framework(let framework):
      try PrivateHeaderGeneration.ArtifactPath(framework.systemLibraryRelativePath)
    case .systemLibraryBundle(let bundle):
      try PrivateHeaderGeneration.ArtifactPath(
        artifactRootForBundleLayout(systemLibraryRelativePath: bundle.relativePath)
      )
    case .usrLibDylib(let dylib):
      try PrivateHeaderGeneration.ArtifactPath("usr/lib/\(dylib.name)")
    case .application(let logicalImagePath):
      try PrivateHeaderGeneration.ArtifactPath(String(URL(fileURLWithPath: logicalImagePath).deletingLastPathComponent().path.dropFirst()))
    }
  }

  fileprivate static func artifactRootForBundleLayout(systemLibraryRelativePath: String) -> String {
    let first = systemLibraryRelativePath.split(separator: "/", maxSplits: 1).first
    if first == "Frameworks" || first == "PrivateFrameworks" { return systemLibraryRelativePath }
    return "SystemLibrary/\(systemLibraryRelativePath)"
  }

  static func inputPath(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    executionMode: PrivateHeaderGeneration.RawDumping.ExecutionMode
  ) -> String {
    switch executionMode {
    case .host: target.inputPath
    case .simulator, .ssh: target.runtimeInputPath
    }
  }

  fileprivate static func stageSystemLibraryRoots(stageDirectory: URL, runtimeRoot: String) -> [URL]
  {
    var roots = [
      stageDirectory.appendingPathComponent("System/Library", isDirectory: true),
      stageDirectory.appendingPathComponent(
        "System/Cryptexes/OS/System/Library", isDirectory: true),
      stageDirectory.appendingPathComponent(
        "System/Volumes/Preboot/Cryptexes/OS/System/Library", isDirectory: true),
    ]
    if runtimeRoot.hasPrefix("/") {
      let base = appendRelativePath(String(runtimeRoot.dropFirst()), to: stageDirectory)
      roots.append(base.appendingPathComponent("System/Library", isDirectory: true))
      roots.append(
        base.appendingPathComponent("System/Cryptexes/OS/System/Library", isDirectory: true))
      roots.append(
        base.appendingPathComponent(
          "System/Volumes/Preboot/Cryptexes/OS/System/Library", isDirectory: true))
    }
    return uniquedByPath(roots)
  }

  fileprivate static func stageUsrLibRoots(stageDirectory: URL, runtimeRoot: String) -> [URL] {
    var roots = [stageDirectory.appendingPathComponent("usr/lib", isDirectory: true)]
    if runtimeRoot.hasPrefix("/") {
      roots.append(
        appendRelativePath(String(runtimeRoot.dropFirst()), to: stageDirectory)
          .appendingPathComponent("usr/lib", isDirectory: true)
      )
    }
    return uniquedByPath(roots)
  }

  fileprivate static func appendRelativePath(_ relativePath: String, to base: URL) -> URL {
    var url = base
    for component in relativePath.split(separator: "/") {
      url.appendPathComponent(String(component), isDirectory: true)
    }
    return url
  }

  fileprivate static func uniquedByPath(_ urls: [URL]) -> [URL] {
    var seen: Set<String> = []
    return urls.filter { seen.insert($0.path).inserted }
  }
}
