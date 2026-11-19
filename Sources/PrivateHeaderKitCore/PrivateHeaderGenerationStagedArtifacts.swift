import Foundation

extension PrivateHeaderGeneration.GenerationExecutor {
  struct StagedArtifacts {
    /// Published path of each staged file.
    let files: [PrivateHeaderGeneration.ArtifactPath: URL]
  }

  struct StrayStagedFiles: Error, CustomStringConvertible {
    let paths: [String]

    var description: String {
      "raw dump wrote files outside the target's output directory: "
        + paths.joined(separator: ", ")
    }
  }

  /// Finds the headers, Swift interfaces, and symbol lists a helper wrote for a target.
  ///
  /// - Throws: `StrayStagedFiles` when the helper also wrote such files outside the
  ///   directory the target publishes from. Publishing the rest would mark an incomplete
  ///   target as completed.
  static func collectStagedArtifacts(
    for target: PrivateHeaderGeneration.TargetDiscovery.DiscoveredTarget,
    in targetStagingDirectory: URL,
    runtimeRoot: String,
    artifactRoot: PrivateHeaderGeneration.ArtifactPath,
    includesAnalysisBinary: Bool = false
  ) throws -> StagedArtifacts {
    var files: [PrivateHeaderGeneration.ArtifactPath: URL] = [:]
    for candidate in stagedSourceDirectoryCandidates(
      for: target,
      in: targetStagingDirectory,
      runtimeRoot: runtimeRoot
    ) {
      let candidatePath = candidate.standardizedFileURL.path
      for url in try regularFiles(under: candidate) {
        let relative = String(url.standardizedFileURL.path.dropFirst(candidatePath.count + 1))
        guard isHeaderArtifact(url)
          || (includesAnalysisBinary && relative == "Analysis/Executable.macho")
        else { continue }
        files[try PrivateHeaderGeneration.ArtifactPath(artifactRoot.rawValue + "/" + relative)] =
          url
      }
      if !files.isEmpty { break }
    }

    let collectedPaths = Set(files.values.map(\.standardizedFileURL.path))
    let strayPaths = try regularFiles(under: targetStagingDirectory)
      .filter(isHeaderArtifact)
      .map(\.standardizedFileURL.path)
      .filter { !collectedPaths.contains($0) }
    guard strayPaths.isEmpty else {
      throw StrayStagedFiles(paths: strayPaths.sorted())
    }
    return StagedArtifacts(files: files)
  }

  static func isHeaderArtifact(_ url: URL) -> Bool {
    ["h", "swiftinterface", "tsv"].contains(url.pathExtension)
  }

  fileprivate static func regularFiles(under directory: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return [] }

    var enumerationError: (any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      )
    else { return [] }

    var files: [URL] = []
    for case let url as URL in enumerator
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files.append(url)
    }
    if let enumerationError { throw enumerationError }
    return files
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
