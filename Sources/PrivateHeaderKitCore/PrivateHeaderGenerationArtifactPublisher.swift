import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package struct ArtifactPublisher: Sendable {
  package struct Draft: Sendable {
    package let generationID: PrivateHeaderGeneration.GenerationID
    package let directory: URL
    package let artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]]
    package let opaquePaths: [PrivateHeaderGeneration.ArtifactPath]
  }

  package struct PreparedGeneration: Sendable {
    package let generationID: PrivateHeaderGeneration.GenerationID
    package let draftDirectory: URL
    package let finalDirectory: URL
    package let marker: PrivateHeaderGeneration.GenerationMarkerSnapshot
  }

  package enum PublisherError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidManagedPath(String)
    case unexpectedItem(path: String, description: String)
    case legacyMigrationRequiresFresh(String)
    case generationAlreadyExists(String)
    case missingArtifact(String)
    case artifactCollision(
      firstPath: String,
      firstOwner: String,
      secondPath: String,
      secondOwner: String
    )
    case inventoryMismatch(expected: [String], actual: [String])
    case markerMismatch(String)
    case posix(operation: String, path: String, errno: Int32)
    case atomicSwapUnsupported(String)

    package var description: String {
      switch self {
      case .invalidManagedPath(let path):
        "managed publication path is invalid: \(path)"
      case .unexpectedItem(let path, let description):
        "unexpected item at \(path): \(description)"
      case .legacyMigrationRequiresFresh(let path):
        "legacy artifact directory requires explicit fresh migration: \(path)"
      case .generationAlreadyExists(let id):
        "generation already exists: \(id)"
      case .missingArtifact(let path):
        "artifact is missing: \(path)"
      case .artifactCollision(let firstPath, let firstOwner, let secondPath, let secondOwner):
        "artifact paths collide: \(firstOwner):\(firstPath) and \(secondOwner):\(secondPath)"
      case .inventoryMismatch(let expected, let actual):
        Self.inventoryMismatchDescription(expected: expected, actual: actual)
      case .markerMismatch(let message):
        "generation marker mismatch: \(message)"
      case .posix(let operation, let path, let error):
        "\(operation) failed for \(path): errno \(error)"
      case .atomicSwapUnsupported(let path):
        "filesystem does not support atomic legacy directory swap at \(path)"
      }
    }

    private static func inventoryMismatchDescription(
      expected: [String],
      actual: [String]
    ) -> String {
      let missing = Array(Set(expected).subtracting(actual)).sorted()
      let unexpected = Array(Set(actual).subtracting(expected)).sorted()
      var details: [String] = []
      if !missing.isEmpty {
        details.append("missing \(summarizedPaths(missing))")
      }
      if !unexpected.isEmpty {
        details.append("unexpected \(summarizedPaths(unexpected))")
      }
      if details.isEmpty {
        details.append("expected \(expected.count) files, found \(actual.count)")
      }
      return "generation inventory mismatch: " + details.joined(separator: "; ")
    }

    private static func summarizedPaths(_ paths: [String]) -> String {
      let limit = 5
      let visible = paths.prefix(limit).joined(separator: ", ")
      let remaining = paths.count - min(paths.count, limit)
      return remaining == 0 ? visible : "\(visible), and \(remaining) more"
    }
  }

  private struct Marker: Codable {
    let generationID: String
    let planFingerprint: String
    let artifactChecksum: String
    let artifactsByTarget: [String: [String]]
    let opaquePaths: [String]
  }

  fileprivate struct OwnedArtifact {
    let path: PrivateHeaderGeneration.ArtifactPath
    let owner: String
  }

  fileprivate final class PortablePathNode {
    struct Child {
      let originalComponent: String
      let node: PortablePathNode
    }

    var children: [String: Child] = [:]
    var firstLeaf: OwnedArtifact?
    var leaf: OwnedArtifact?
  }

  fileprivate struct TargetMutationPlan {
    struct Copy {
      let source: URL
      let destination: URL
    }

    let pathsToRemove: [PrivateHeaderGeneration.ArtifactPath]
    let copies: [Copy]
    let artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]]
    let opaquePaths: [PrivateHeaderGeneration.ArtifactPath]
  }

  struct ProspectiveNamespace {
    fileprivate enum NodeKind {
      case directory
      case regular
    }

    fileprivate struct Node {
      let path: PrivateHeaderGeneration.ArtifactPath
      let kind: NodeKind
      let recordedByOwnership: Bool
      var observedDirectoryPath: PrivateHeaderGeneration.ArtifactPath?
    }

    private var nodes: [[String]: Node] = [:]
    private var childCounts: [[String]: Int] = [:]
    private var ownershipCounts: [[String]: Int] = [:]

    init(
      ownedPaths: [PrivateHeaderGeneration.ArtifactPath],
      existingDirectories: [PrivateHeaderGeneration.ArtifactPath],
      existingRegularPaths: [PrivateHeaderGeneration.ArtifactPath],
      pathsToRemove: [PrivateHeaderGeneration.ArtifactPath]
    ) throws {
      let ownedSet = Set(ownedPaths)
      let existingRegularSet = Set(existingRegularPaths)
      guard ownedSet.count == ownedPaths.count,
        existingRegularSet.count == existingRegularPaths.count,
        ownedSet == existingRegularSet
      else {
        throw PublisherError.inventoryMismatch(
          expected: ownedPaths.map(\.rawValue).sorted(),
          actual: existingRegularPaths.map(\.rawValue).sorted()
        )
      }

      var ownedPathByCanonicalPath:
        [PrivateHeaderGeneration.ArtifactPath: PrivateHeaderGeneration.ArtifactPath] = [:]
      for ownedPath in ownedPaths.sorted(by: ArtifactPublisher.artifactPathPrecedes) {
        ownedPathByCanonicalPath[ownedPath] = ownedPath
        let components = ownedPath.rawValue.split(separator: "/").map(String.init)
        for componentCount in 1..<components.count {
          let directory = PrivateHeaderGeneration.ArtifactPath(
            rawValue: components.prefix(componentCount).joined(separator: "/")
          )
          try insertRecorded(directory, kind: .directory)
          ownershipCounts[ArtifactPublisher.portablePathComponents(directory), default: 0] += 1
        }
        try insertRecorded(ownedPath, kind: .regular)
      }

      for directory in existingDirectories.sorted(by: Self.namespacePathPrecedes) {
        try insertObservedDirectory(directory)
      }

      for key in nodes.keys where !key.isEmpty {
        childCounts[Array(key.dropLast()), default: 0] += 1
      }
      for path in pathsToRemove {
        guard let ownedPath = ownedPathByCanonicalPath[path] else {
          throw PublisherError.missingArtifact(path.rawValue)
        }
        try removeRegularFile(ownedPath)
      }
    }

    func preflightDestination(
      _ artifact: PrivateHeaderGeneration.ArtifactPath,
      destination: URL
    ) throws {
      let components = artifact.rawValue.split(separator: "/").map(String.init)
      var key: [String] = []
      for (index, component) in components.enumerated() {
        key.append(ArtifactPublisher.portableComponentKey(component))
        guard let node = nodes[key] else {
          return
        }
        let requestedPath = PrivateHeaderGeneration.ArtifactPath(
          rawValue: components.prefix(index + 1).joined(separator: "/")
        )
        let existingPath =
          node.kind == .directory && ownershipCounts[key, default: 0] == 0
          ? node.observedDirectoryPath ?? node.path
          : node.path
        guard existingPath.rawValue.utf8.elementsEqual(requestedPath.rawValue.utf8) else {
          throw PublisherError.unexpectedItem(
            path: destination.path,
            description: "portable alias of existing path \(existingPath.rawValue)"
          )
        }
        let isLeaf = index == components.count - 1
        if isLeaf {
          throw PublisherError.unexpectedItem(
            path: destination.path,
            description: node.kind == .directory
              ? "artifact destination is an existing directory"
              : "artifact destination is an existing regular file"
          )
        }
        guard node.kind == .directory else {
          throw PublisherError.unexpectedItem(
            path: destination.path,
            description: "artifact destination parent is a regular file"
          )
        }
      }
    }

    private static func namespacePathPrecedes(
      _ lhs: PrivateHeaderGeneration.ArtifactPath,
      _ rhs: PrivateHeaderGeneration.ArtifactPath
    ) -> Bool {
      let lhsCount = lhs.rawValue.split(separator: "/").count
      let rhsCount = rhs.rawValue.split(separator: "/").count
      if lhsCount != rhsCount { return lhsCount < rhsCount }
      return ArtifactPublisher.artifactPathPrecedes(lhs, rhs)
    }

    private mutating func insertRecorded(
      _ path: PrivateHeaderGeneration.ArtifactPath,
      kind: NodeKind
    ) throws {
      let key = ArtifactPublisher.portablePathComponents(path)
      if let existing = nodes[key] {
        guard existing.kind == kind,
          existing.recordedByOwnership,
          existing.path.rawValue.utf8.elementsEqual(path.rawValue.utf8)
        else {
          throw PublisherError.unexpectedItem(
            path: path.rawValue,
            description: "portable alias of existing path \(existing.path.rawValue)"
          )
        }
        return
      }
      nodes[key] = Node(
        path: path,
        kind: kind,
        recordedByOwnership: true,
        observedDirectoryPath: nil
      )
    }

    private mutating func insertObservedDirectory(
      _ path: PrivateHeaderGeneration.ArtifactPath
    ) throws {
      let key = ArtifactPublisher.portablePathComponents(path)
      guard var existing = nodes[key] else {
        nodes[key] = Node(
          path: path,
          kind: .directory,
          recordedByOwnership: false,
          observedDirectoryPath: path
        )
        return
      }
      let matchesRecordedPrefix = existing.recordedByOwnership && existing.path == path
      let matchesObservedDirectory =
        existing.observedDirectoryPath.map {
          $0.rawValue.utf8.elementsEqual(path.rawValue.utf8)
        } ?? false
      guard existing.kind == .directory,
        matchesObservedDirectory || (existing.observedDirectoryPath == nil && matchesRecordedPrefix)
      else {
        throw PublisherError.unexpectedItem(
          path: path.rawValue,
          description: "portable alias of existing path \(existing.path.rawValue)"
        )
      }
      if existing.observedDirectoryPath == nil {
        existing.observedDirectoryPath = path
        nodes[key] = existing
      }
    }

    private mutating func removeRegularFile(
      _ path: PrivateHeaderGeneration.ArtifactPath
    ) throws {
      var key = ArtifactPublisher.portablePathComponents(path)
      guard let node = nodes[key], node.kind == .regular, node.path == path else {
        throw PublisherError.missingArtifact(path.rawValue)
      }
      for componentCount in 1..<key.count {
        let directoryKey = Array(key.prefix(componentCount))
        guard let count = ownershipCounts[directoryKey], count > 0 else {
          preconditionFailure("prospective namespace ownership count is inconsistent")
        }
        ownershipCounts[directoryKey] = count - 1
      }
      removeNode(at: key)
      key.removeLast()
      while !key.isEmpty,
        let parent = nodes[key],
        parent.kind == .directory,
        childCounts[key, default: 0] == 0
      {
        removeNode(at: key)
        key.removeLast()
      }
    }

    private mutating func removeNode(at key: [String]) {
      precondition(nodes.removeValue(forKey: key) != nil)
      childCounts.removeValue(forKey: key)
      ownershipCounts.removeValue(forKey: key)
      guard !key.isEmpty else { return }
      let parent = Array(key.dropLast())
      guard let count = childCounts[parent], count > 0 else {
        preconditionFailure("prospective namespace child count is inconsistent")
      }
      childCounts[parent] = count - 1
    }
  }

  fileprivate struct InventoriedItem {
    let path: PrivateHeaderGeneration.ArtifactPath
    let url: URL
    let kind: ManagedFileSystem.ItemKind
  }

  private typealias ItemKind = ManagedFileSystem.ItemKind

  package let artifactBaseDirectory: URL
  package let sourceLabel: String

  package init(artifactBaseDirectory: URL, sourceLabel: String) throws {
    self.artifactBaseDirectory = try Self.canonicalizedOutputURL(artifactBaseDirectory)
    self.sourceLabel = sourceLabel
  }

  package var stableURL: URL {
    artifactBaseDirectory.appendingPathComponent(sourceLabel, isDirectory: false)
  }

  package var managedRoot: URL {
    artifactBaseDirectory
      .appendingPathComponent(".privateheaderkit", isDirectory: true)
      .appendingPathComponent(sourceLabel, isDirectory: true)
  }

  package var lockURL: URL {
    managedRoot.appendingPathComponent("generation.lock", isDirectory: false)
  }

  package var currentURL: URL {
    managedRoot.appendingPathComponent("current", isDirectory: false)
  }

  private var generationsURL: URL {
    managedRoot.appendingPathComponent("generations", isDirectory: true)
  }

  private var stagingURL: URL {
    managedRoot.appendingPathComponent("staging", isDirectory: true)
  }

  private var legacyBackupsURL: URL {
    managedRoot.appendingPathComponent("legacy-backups", isDirectory: true)
  }

  package func prepareForLease() throws {
    try prepareManagedDirectories()
  }

  package func inspect() throws -> PrivateHeaderGeneration.PublicationSnapshot {
    try validateBaseURL()
    let stableState = try stablePathState()
    let markers = try generationMarkers()
    let currentGenerationID = try readCurrentGenerationID()
    if let currentGenerationID, markers[currentGenerationID] == nil {
      throw PublisherError.markerMismatch(
        "current points to generation without a valid marker: \(currentGenerationID.rawValue)"
      )
    }
    if stableState == .managed, currentGenerationID == nil {
      throw PublisherError.markerMismatch("stable path is managed but current is absent")
    }
    return PrivateHeaderGeneration.PublicationSnapshot(
      currentGenerationID: currentGenerationID,
      stablePathState: stableState,
      markers: markers
    )
  }

  package func beginDraft(
    generationID: PrivateHeaderGeneration.GenerationID,
    allowLegacyMigration: Bool
  ) throws -> Draft {
    try prepareManagedDirectories()
    let snapshot = try inspect()
    let draftDirectory = stagingURL.appendingPathComponent(
      generationID.rawValue + ".draft",
      isDirectory: true
    )
    if try itemKind(at: draftDirectory) != nil {
      try FileManager.default.removeItem(at: draftDirectory)
    }
    if try itemKind(at: generationURL(generationID)) != nil {
      throw PublisherError.generationAlreadyExists(generationID.rawValue)
    }

    if let marker = snapshot.currentMarker {
      try FileManager.default.copyItem(at: generationURL(marker.generationID), to: draftDirectory)
      let markerURL = draftDirectory.appendingPathComponent(Self.markerName, isDirectory: false)
      try FileManager.default.removeItem(at: markerURL)
      return Draft(
        generationID: generationID,
        directory: draftDirectory,
        artifactsByTarget: marker.artifactsByTarget,
        opaquePaths: marker.opaquePaths
      )
    }

    if snapshot.stablePathState == .legacyDirectory {
      guard allowLegacyMigration else {
        throw PublisherError.legacyMigrationRequiresFresh(stableURL.path)
      }
      let opaquePaths = try inventoryLegacyFiles(at: stableURL)
      try FileManager.default.copyItem(at: stableURL, to: draftDirectory)
      return Draft(
        generationID: generationID,
        directory: draftDirectory,
        artifactsByTarget: [:],
        opaquePaths: opaquePaths
      )
    }

    try FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: false)
    return Draft(
      generationID: generationID,
      directory: draftDirectory,
      artifactsByTarget: [:],
      opaquePaths: []
    )
  }

  package func applyCompletedTarget(
    targetID: String,
    files: [PrivateHeaderGeneration.ArtifactPath: URL],
    to draft: Draft
  ) throws -> Draft {
    try applyCompletedTargets([targetID: files], to: draft)
  }

  package func validateTargetReplacement(
    targetID: String,
    artifacts: [PrivateHeaderGeneration.ArtifactPath],
    existingArtifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    opaquePaths: [PrivateHeaderGeneration.ArtifactPath]
  ) throws {
    var prospectiveArtifactsByTarget = existingArtifactsByTarget
    prospectiveArtifactsByTarget[targetID] = artifacts
    let incomingKeys = Set(artifacts.map(Self.lexicalPathKey))
    let remainingOpaquePaths = opaquePaths.filter {
      !incomingKeys.contains(Self.lexicalPathKey($0))
    }
    try Self.validatePortableOwnership(
      artifactsByTarget: prospectiveArtifactsByTarget,
      opaquePaths: remainingOpaquePaths
    )
  }

  package func applyCompletedTargets(
    _ filesByTarget: [String: [PrivateHeaderGeneration.ArtifactPath: URL]],
    to draft: Draft
  ) throws -> Draft {
    try applyCompletedTargets(filesByTarget, to: draft, removesAbsentTargets: false)
  }

  package func replaceCompletedTargets(
    _ filesByTarget: [String: [PrivateHeaderGeneration.ArtifactPath: URL]],
    in draft: Draft
  ) throws -> Draft {
    try applyCompletedTargets(filesByTarget, to: draft, removesAbsentTargets: true)
  }

  private func applyCompletedTargets(
    _ filesByTarget: [String: [PrivateHeaderGeneration.ArtifactPath: URL]],
    to draft: Draft,
    removesAbsentTargets: Bool
  ) throws -> Draft {
    if filesByTarget.isEmpty, !removesAbsentTargets {
      return draft
    }
    guard try itemKind(at: draft.directory) == .directory else {
      throw PublisherError.unexpectedItem(
        path: draft.directory.path,
        description: "expected draft directory"
      )
    }

    var artifactsByTarget = removesAbsentTargets ? [:] : draft.artifactsByTarget
    var incomingFiles:
      [(targetID: String, path: PrivateHeaderGeneration.ArtifactPath, source: URL)] = []
    var incomingPathKeys: Set<[UInt8]> = []
    var pathsToRemove: [PrivateHeaderGeneration.ArtifactPath] =
      removesAbsentTargets ? draft.artifactsByTarget.values.flatMap { $0 } : []

    for targetID in filesByTarget.keys.sorted() {
      guard let files = filesByTarget[targetID], !files.isEmpty else {
        throw PublisherError.missingArtifact("target \(targetID) produced no files")
      }
      let sortedFiles = files.sorted { $0.key.rawValue < $1.key.rawValue }
      artifactsByTarget[targetID] = sortedFiles.map(\.key)
      pathsToRemove += draft.artifactsByTarget[targetID] ?? []
      for (path, source) in sortedFiles {
        incomingPathKeys.insert(Self.lexicalPathKey(path))
        incomingFiles.append((targetID, path, source))
      }
    }

    let claimedOpaquePaths = draft.opaquePaths.filter {
      incomingPathKeys.contains(Self.lexicalPathKey($0))
    }
    pathsToRemove += claimedOpaquePaths
    var seenRemovalKeys: Set<[UInt8]> = []
    pathsToRemove =
      pathsToRemove
      .filter { seenRemovalKeys.insert(Self.lexicalPathKey($0)).inserted }
      .sorted { Self.lexicalStringPrecedes($0.rawValue, $1.rawValue) }
    let opaquePaths = draft.opaquePaths.filter {
      !incomingPathKeys.contains(Self.lexicalPathKey($0))
    }.sorted {
      Self.lexicalStringPrecedes($0.rawValue, $1.rawValue)
    }

    try Self.validatePortableOwnership(
      artifactsByTarget: draft.artifactsByTarget,
      opaquePaths: draft.opaquePaths
    )
    try Self.validatePortableOwnership(
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
    for path in pathsToRemove {
      try preflightRemoval(path, from: draft.directory)
    }

    let existingItems = try inventoryItems(
      at: draft.directory,
      allowHidden: true,
      allowedExtensions: nil
    )
    let namespace = try ProspectiveNamespace(
      ownedPaths: draft.artifactsByTarget.values.flatMap { $0 } + draft.opaquePaths,
      existingDirectories: existingItems.compactMap {
        $0.kind == .directory ? $0.path : nil
      },
      existingRegularPaths: existingItems.compactMap {
        $0.kind == .regular ? $0.path : nil
      },
      pathsToRemove: pathsToRemove
    )

    var copies: [TargetMutationPlan.Copy] = []
    copies.reserveCapacity(incomingFiles.count)
    for incoming in incomingFiles.sorted(by: {
      if $0.path != $1.path { return $0.path.rawValue < $1.path.rawValue }
      return $0.targetID < $1.targetID
    }) {
      guard try itemKind(at: incoming.source) == .regular else {
        throw PublisherError.unexpectedItem(
          path: incoming.source.path,
          description: "expected regular file"
        )
      }
      let destination = try artifactURL(incoming.path, in: draft.directory)
      try namespace.preflightDestination(incoming.path, destination: destination)
      copies.append(.init(source: incoming.source, destination: destination))
    }

    for path in pathsToRemove {
      try removeOwnedArtifact(path, from: draft.directory)
    }
    for copy in copies {
      guard try itemKind(at: copy.destination) == nil else {
        throw PublisherError.unexpectedItem(
          path: copy.destination.path,
          description: "artifact destination changed after preflight"
        )
      }
      try FileManager.default.createDirectory(
        at: copy.destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.copyItem(at: copy.source, to: copy.destination)
    }
    return Draft(
      generationID: draft.generationID,
      directory: draft.directory,
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
  }

  package func validateRawStaging(
    root: URL,
    expectedSourceFiles: Set<URL>
  ) throws {
    let actualFiles = try inventoryRegularFiles(
      at: root,
      allowHidden: false,
      allowedExtensions: ["h", "swiftinterface"]
    )
    let expected = Set(expectedSourceFiles.map { $0.standardizedFileURL.path })
    let actual = Set(actualFiles.map { $0.url.standardizedFileURL.path })
    guard expected == actual else {
      throw PublisherError.inventoryMismatch(
        expected: expected.sorted(),
        actual: actual.sorted()
      )
    }
  }

  package func prepareGeneration(
    _ draft: Draft,
    planFingerprint: String
  ) throws -> PreparedGeneration {
    try removeFinderMetadata(in: draft.directory)
    try Self.validatePortableOwnership(
      artifactsByTarget: draft.artifactsByTarget,
      opaquePaths: draft.opaquePaths
    )
    let actual = try inventoryRegularFiles(
      at: draft.directory,
      allowHidden: true,
      allowedExtensions: nil
    )
    let actualPaths = Set(actual.map(\.path))
    let ownedPaths = Set(draft.artifactsByTarget.values.flatMap { $0 })
    let expectedPaths = ownedPaths.union(draft.opaquePaths)
    guard actualPaths == expectedPaths else {
      throw PublisherError.inventoryMismatch(
        expected: expectedPaths.map(\.rawValue).sorted(),
        actual: actualPaths.map(\.rawValue).sorted()
      )
    }

    let checksum = Self.artifactChecksum(
      planFingerprint: planFingerprint,
      artifactsByTarget: draft.artifactsByTarget,
      opaquePaths: draft.opaquePaths
    )
    let marker = PrivateHeaderGeneration.GenerationMarkerSnapshot(
      generationID: draft.generationID,
      planFingerprint: planFingerprint,
      artifactChecksum: checksum,
      artifactsByTarget: draft.artifactsByTarget.mapValues {
        $0.sorted { $0.rawValue < $1.rawValue }
      },
      opaquePaths: draft.opaquePaths.sorted { $0.rawValue < $1.rawValue }
    )
    try writeMarker(marker, to: draft.directory)
    _ = try validateGeneration(at: draft.directory, expectedID: draft.generationID)
    return PreparedGeneration(
      generationID: draft.generationID,
      draftDirectory: draft.directory,
      finalDirectory: generationURL(draft.generationID),
      marker: marker
    )
  }

  package func movePreparedGeneration(_ generation: PreparedGeneration) throws {
    guard try itemKind(at: generation.finalDirectory) == nil else {
      throw PublisherError.generationAlreadyExists(generation.generationID.rawValue)
    }
    try atomicRename(from: generation.draftDirectory, to: generation.finalDirectory)
    try syncDirectory(generationsURL)
    let validated = try validateGeneration(
      at: generation.finalDirectory,
      expectedID: generation.generationID
    )
    guard validated == generation.marker else {
      throw PublisherError.markerMismatch("generation changed after final move")
    }
  }

  package func switchCurrent(to generationID: PrivateHeaderGeneration.GenerationID) throws {
    _ = try validateGeneration(at: generationURL(generationID), expectedID: generationID)
    let temporary = managedRoot.appendingPathComponent(
      ".current-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    try createSymbolicLink(at: temporary, destination: "generations/\(generationID.rawValue)")
    do {
      try atomicRename(from: temporary, to: currentURL)
    } catch {
      let renameError = error
      do {
        try FileManager.default.removeItem(at: temporary)
      } catch {
        throw PublisherError.unexpectedItem(
          path: temporary.path,
          description:
            "current pointer switch failed with \(renameError), and temporary link cleanup failed: \(error)"
        )
      }
      throw renameError
    }
    try syncDirectory(managedRoot)
  }

  package func ensureStablePointer() throws {
    let state = try stablePathState()
    switch state {
    case .managed:
      return
    case .absent:
      let temporary = artifactBaseDirectory.appendingPathComponent(
        ".privateheaderkit-link-\(UUID().uuidString.lowercased())",
        isDirectory: false
      )
      try createSymbolicLink(at: temporary, destination: stableLinkDestination)
      do {
        try atomicRename(from: temporary, to: stableURL)
      } catch {
        let renameError = error
        do {
          try FileManager.default.removeItem(at: temporary)
        } catch {
          throw PublisherError.unexpectedItem(
            path: temporary.path,
            description:
              "stable pointer switch failed with \(renameError), and temporary link cleanup failed: \(error)"
          )
        }
        throw renameError
      }
      try syncDirectory(artifactBaseDirectory)
    case .legacyDirectory:
      try swapLegacyDirectoryForStableLink()
    }
  }

  package func discardGeneration(_ generationID: PrivateHeaderGeneration.GenerationID) throws {
    if try readCurrentGenerationID() == generationID {
      throw PublisherError.markerMismatch("refusing to discard current generation")
    }
    let url = generationURL(generationID)
    if try itemKind(at: url) != nil {
      _ = try validateGeneration(at: url, expectedID: generationID)
      try FileManager.default.removeItem(at: url)
      try syncDirectory(generationsURL)
    }
  }

  package func discardDraft(_ draft: Draft) throws {
    if try itemKind(at: draft.directory) != nil {
      try FileManager.default.removeItem(at: draft.directory)
    }
  }

  package func cleanupStaging() throws {
    guard try itemKind(at: stagingURL) != nil else { return }
    let entries = try FileManager.default.contentsOfDirectory(
      at: stagingURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    for entry in entries {
      try FileManager.default.removeItem(at: entry)
    }
    try syncDirectory(stagingURL)
  }

  package func validateCommittedCurrent(
    _ generationID: PrivateHeaderGeneration.GenerationID
  ) throws {
    guard try stablePathState() == .managed else {
      throw PublisherError.markerMismatch("committed stable pointer is not managed")
    }
    guard try readCurrentGenerationID() == generationID else {
      throw PublisherError.markerMismatch("committed generation is not current")
    }
    _ = try validateGeneration(at: generationURL(generationID), expectedID: generationID)
  }

  package func retainGenerations(
    protected: Set<PrivateHeaderGeneration.GenerationID>,
    maximumCount: Int = 3
  ) throws {
    precondition(maximumCount >= protected.count)
    let markers = try generationMarkers()
    let datedCandidates = try markers.keys
      .filter { !protected.contains($0) }
      .map { id -> (PrivateHeaderGeneration.GenerationID, Date) in
        let values = try generationURL(id).resourceValues(forKeys: [.contentModificationDateKey])
        guard let date = values.contentModificationDate else {
          throw PublisherError.unexpectedItem(
            path: generationURL(id).path,
            description: "missing content modification date"
          )
        }
        return (id, date)
      }
    let candidates = datedCandidates.sorted { lhs, rhs in
      if lhs.1 == rhs.1 { return lhs.0.rawValue < rhs.0.rawValue }
      return lhs.1 < rhs.1
    }.map(\.0)
    let removeCount = max(0, markers.count - maximumCount)
    for id in candidates.prefix(removeCount) {
      try discardGeneration(id)
    }
  }
}

extension ArtifactPublisher {
  fileprivate static let markerName = ".privateheaderkit-generation.json"

  fileprivate var stableLinkDestination: String {
    ".privateheaderkit/\(sourceLabel)/current"
  }

  fileprivate func validateBaseURL() throws {
    guard artifactBaseDirectory.isFileURL,
      PrivateHeaderGeneration.RunID.isSafeComponent(sourceLabel)
    else {
      throw PublisherError.invalidManagedPath(artifactBaseDirectory.path)
    }
  }

  fileprivate func prepareManagedDirectories() throws {
    try validateBaseURL()
    try ensureDirectoryWithoutSymlinks(artifactBaseDirectory)
    try ensureDirectoryWithoutSymlinks(
      artifactBaseDirectory.appendingPathComponent(".privateheaderkit", isDirectory: true))
    try ensureDirectoryWithoutSymlinks(managedRoot)
    try ensureDirectoryWithoutSymlinks(generationsURL)
    try ensureDirectoryWithoutSymlinks(stagingURL)
  }

  fileprivate func targetMutationPlan(
    targetID: String,
    files: [PrivateHeaderGeneration.ArtifactPath: URL],
    draft: Draft
  ) throws -> TargetMutationPlan {
    guard !files.isEmpty else {
      throw PublisherError.missingArtifact("target \(targetID) produced no files")
    }
    guard try itemKind(at: draft.directory) == .directory else {
      throw PublisherError.unexpectedItem(
        path: draft.directory.path,
        description: "expected draft directory"
      )
    }

    let sortedFiles = files.sorted { $0.key.rawValue < $1.key.rawValue }
    let incomingPathKeys = Set(sortedFiles.map { Self.lexicalPathKey($0.key) })
    let claimedOpaquePaths = draft.opaquePaths.filter {
      incomingPathKeys.contains(Self.lexicalPathKey($0))
    }
    var seenRemovalKeys: Set<[UInt8]> = []
    let pathsToRemove = ((draft.artifactsByTarget[targetID] ?? []) + claimedOpaquePaths)
      .filter { seenRemovalKeys.insert(Self.lexicalPathKey($0)).inserted }
      .sorted { Self.lexicalStringPrecedes($0.rawValue, $1.rawValue) }
    var artifactsByTarget = draft.artifactsByTarget
    artifactsByTarget[targetID] = sortedFiles.map(\.key)
    let opaquePaths = draft.opaquePaths.filter {
      !incomingPathKeys.contains(Self.lexicalPathKey($0))
    }.sorted {
      Self.lexicalStringPrecedes($0.rawValue, $1.rawValue)
    }
    try Self.validatePortableOwnership(
      artifactsByTarget: draft.artifactsByTarget,
      opaquePaths: draft.opaquePaths
    )
    try Self.validatePortableOwnership(
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
    for path in pathsToRemove {
      try preflightRemoval(path, from: draft.directory)
    }
    let existingItems = try inventoryItems(
      at: draft.directory,
      allowHidden: true,
      allowedExtensions: nil
    )
    let existingRegularPaths = existingItems.compactMap {
      $0.kind == .regular ? $0.path : nil
    }
    let existingDirectories = existingItems.compactMap {
      $0.kind == .directory ? $0.path : nil
    }
    let namespace = try ProspectiveNamespace(
      ownedPaths: draft.artifactsByTarget.values.flatMap { $0 } + draft.opaquePaths,
      existingDirectories: existingDirectories,
      existingRegularPaths: existingRegularPaths,
      pathsToRemove: pathsToRemove
    )

    var copies: [TargetMutationPlan.Copy] = []
    copies.reserveCapacity(sortedFiles.count)
    for (path, source) in sortedFiles {
      guard try itemKind(at: source) == .regular else {
        throw PublisherError.unexpectedItem(
          path: source.path,
          description: "expected regular file"
        )
      }
      let destination = try artifactURL(path, in: draft.directory)
      try namespace.preflightDestination(path, destination: destination)
      copies.append(.init(source: source, destination: destination))
    }
    return TargetMutationPlan(
      pathsToRemove: pathsToRemove,
      copies: copies,
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
  }

  fileprivate func preflightRemoval(
    _ artifact: PrivateHeaderGeneration.ArtifactPath,
    from root: URL
  ) throws {
    let components = artifact.rawValue.split(separator: "/").map(String.init)
    var current = root
    for (index, component) in components.enumerated() {
      current.appendPathComponent(component, isDirectory: false)
      guard let kind = try itemKind(at: current) else {
        throw PublisherError.missingArtifact(current.path)
      }
      let isLeaf = index == components.count - 1
      if isLeaf {
        guard kind == .regular else {
          throw PublisherError.unexpectedItem(
            path: current.path,
            description: "owned artifact is not a regular file"
          )
        }
      } else {
        guard kind == .directory else {
          throw PublisherError.unexpectedItem(
            path: current.path,
            description: "owned artifact parent is not a real directory"
          )
        }
      }
    }
  }

  fileprivate static func validatePortableOwnership(
    artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    opaquePaths: [PrivateHeaderGeneration.ArtifactPath]
  ) throws {
    var entries: [OwnedArtifact] = []
    for targetID in artifactsByTarget.keys.sorted() {
      entries += artifactsByTarget[targetID, default: []].map {
        OwnedArtifact(path: $0, owner: targetID)
      }
    }
    entries += opaquePaths.map { OwnedArtifact(path: $0, owner: "opaque") }
    entries.sort(by: ownedArtifactPrecedes)

    let root = PortablePathNode()
    for entry in entries {
      let rawComponents = entry.path.rawValue.split(separator: "/").map(String.init)
      let portableComponents = rawComponents.map(portableComponentKey)
      var node = root
      var visitedNodes = [root]
      for (rawComponent, portableComponent) in zip(rawComponents, portableComponents) {
        if let shorterPath = node.leaf {
          throw collision(shorterPath, entry)
        }
        if let child = node.children[portableComponent] {
          if !child.originalComponent.utf8.elementsEqual(rawComponent.utf8) {
            guard let aliasedPath = child.node.firstLeaf else {
              preconditionFailure("portable path trie child has no representative leaf")
            }
            throw collision(aliasedPath, entry)
          }
          node = child.node
        } else {
          let child = PortablePathNode()
          node.children[portableComponent] = .init(
            originalComponent: rawComponent,
            node: child
          )
          node = child
        }
        visitedNodes.append(node)
      }
      if let duplicate = node.leaf {
        throw collision(duplicate, entry)
      }
      if let longerPath = node.firstLeaf {
        throw collision(longerPath, entry)
      }
      node.leaf = entry
      for visitedNode in visitedNodes where visitedNode.firstLeaf == nil {
        visitedNode.firstLeaf = entry
      }
    }
  }

  fileprivate static func collision(
    _ first: OwnedArtifact,
    _ second: OwnedArtifact
  ) -> PublisherError {
    let pair = [first, second].sorted(by: ownedArtifactPrecedes)
    return .artifactCollision(
      firstPath: pair[0].path.rawValue,
      firstOwner: pair[0].owner,
      secondPath: pair[1].path.rawValue,
      secondOwner: pair[1].owner
    )
  }

  fileprivate static func ownedArtifactPrecedes(
    _ lhs: OwnedArtifact,
    _ rhs: OwnedArtifact
  ) -> Bool {
    if !lhs.path.rawValue.utf8.elementsEqual(rhs.path.rawValue.utf8) {
      return lexicalStringPrecedes(lhs.path.rawValue, rhs.path.rawValue)
    }
    return lexicalStringPrecedes(lhs.owner, rhs.owner)
  }

  fileprivate static func lexicalPathKey(
    _ path: PrivateHeaderGeneration.ArtifactPath
  ) -> [UInt8] {
    Array(path.rawValue.utf8)
  }

  fileprivate static func portablePathComponents(
    _ path: PrivateHeaderGeneration.ArtifactPath
  ) -> [String] {
    path.rawValue.split(separator: "/").map { portableComponentKey(String($0)) }
  }

  fileprivate static func artifactPathPrecedes(
    _ lhs: PrivateHeaderGeneration.ArtifactPath,
    _ rhs: PrivateHeaderGeneration.ArtifactPath
  ) -> Bool {
    lexicalStringPrecedes(lhs.rawValue, rhs.rawValue)
  }

  fileprivate static func lexicalStringPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  fileprivate static func portableComponentKey(_ component: String) -> String {
    component
      .precomposedStringWithCanonicalMapping
      .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }

  fileprivate static func canonicalizedOutputURL(_ url: URL) throws -> URL {
    do {
      return try ManagedFileSystem.canonicalizedDirectoryResolvingExistingAncestor(url)
    } catch let error as ManagedFileSystem.Failure {
      throw mapManagedFileSystemFailure(error)
    }
  }

  fileprivate func ensureDirectoryWithoutSymlinks(_ url: URL) throws {
    do {
      try ManagedFileSystem.ensureRealDirectory(url)
    } catch let error as ManagedFileSystem.Failure {
      throw Self.mapManagedFileSystemFailure(error)
    }
  }

  fileprivate func generationURL(_ generationID: PrivateHeaderGeneration.GenerationID) -> URL {
    generationsURL.appendingPathComponent(generationID.rawValue, isDirectory: true)
  }

  fileprivate func stablePathState() throws -> PrivateHeaderGeneration.StablePathState {
    guard let kind = try itemKind(at: stableURL) else { return .absent }
    switch kind {
    case .directory:
      return .legacyDirectory
    case .symbolicLink:
      let destination = try FileManager.default.destinationOfSymbolicLink(atPath: stableURL.path)
      guard destination == stableLinkDestination else {
        throw PublisherError.unexpectedItem(
          path: stableURL.path,
          description: "symlink points to \(destination)"
        )
      }
      return .managed
    case .regular, .other:
      throw PublisherError.unexpectedItem(
        path: stableURL.path, description: "expected directory or managed symlink")
    }
  }

  fileprivate func readCurrentGenerationID() throws -> PrivateHeaderGeneration.GenerationID? {
    guard let kind = try itemKind(at: currentURL) else { return nil }
    guard kind == .symbolicLink else {
      throw PublisherError.unexpectedItem(
        path: currentURL.path, description: "expected symbolic link")
    }
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
    let components = destination.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    guard components.count == 2, components[0] == "generations" else {
      throw PublisherError.markerMismatch("current has unsafe destination \(destination)")
    }
    return try PrivateHeaderGeneration.GenerationID(components[1])
  }

  fileprivate func generationMarkers() throws -> [PrivateHeaderGeneration.GenerationID:
    PrivateHeaderGeneration.GenerationMarkerSnapshot]
  {
    guard try itemKind(at: generationsURL) != nil else { return [:] }
    let entries = try FileManager.default.contentsOfDirectory(
      at: generationsURL,
      includingPropertiesForKeys: nil,
      options: []
    )
    var markers:
      [PrivateHeaderGeneration.GenerationID: PrivateHeaderGeneration.GenerationMarkerSnapshot] = [:]
    for entry in entries {
      guard try itemKind(at: entry) == .directory else {
        throw PublisherError.unexpectedItem(
          path: entry.path, description: "generation entry is not a directory")
      }
      let id = try PrivateHeaderGeneration.GenerationID(entry.lastPathComponent)
      markers[id] = try validateGeneration(at: entry, expectedID: id)
    }
    return markers
  }

  fileprivate func validateGeneration(
    at directory: URL,
    expectedID: PrivateHeaderGeneration.GenerationID
  ) throws -> PrivateHeaderGeneration.GenerationMarkerSnapshot {
    let markerURL = directory.appendingPathComponent(Self.markerName, isDirectory: false)
    guard try itemKind(at: markerURL) == .regular else {
      throw PublisherError.markerMismatch("missing marker for \(expectedID.rawValue)")
    }
    let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
    var artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]] = [:]
    for (targetID, paths) in marker.artifactsByTarget {
      artifactsByTarget[targetID] = try paths.map { try PrivateHeaderGeneration.ArtifactPath($0) }
    }
    let opaquePaths = try marker.opaquePaths.map { try PrivateHeaderGeneration.ArtifactPath($0) }
    try Self.validatePortableOwnership(
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
    guard marker.generationID == expectedID.rawValue else {
      throw PublisherError.markerMismatch("directory and marker generation IDs differ")
    }
    let checksum = Self.artifactChecksum(
      planFingerprint: marker.planFingerprint,
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
    guard checksum == marker.artifactChecksum else {
      throw PublisherError.markerMismatch("artifact checksum does not match marker inventory")
    }
    let files = try inventoryRegularFiles(at: directory, allowHidden: true, allowedExtensions: nil)
      .filter { $0.path.rawValue != Self.markerName }
    let actual = Set(files.map(\.path))
    let expected = Set(artifactsByTarget.values.flatMap { $0 }).union(opaquePaths)
    guard actual == expected else {
      throw PublisherError.inventoryMismatch(
        expected: expected.map(\.rawValue).sorted(),
        actual: actual.map(\.rawValue).sorted()
      )
    }
    return PrivateHeaderGeneration.GenerationMarkerSnapshot(
      generationID: expectedID,
      planFingerprint: marker.planFingerprint,
      artifactChecksum: marker.artifactChecksum,
      artifactsByTarget: artifactsByTarget,
      opaquePaths: opaquePaths
    )
  }

  fileprivate func writeMarker(
    _ snapshot: PrivateHeaderGeneration.GenerationMarkerSnapshot,
    to directory: URL
  ) throws {
    let marker = Marker(
      generationID: snapshot.generationID.rawValue,
      planFingerprint: snapshot.planFingerprint,
      artifactChecksum: snapshot.artifactChecksum,
      artifactsByTarget: snapshot.artifactsByTarget.mapValues { $0.map(\.rawValue).sorted() },
      opaquePaths: snapshot.opaquePaths.map(\.rawValue).sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let markerURL = directory.appendingPathComponent(Self.markerName, isDirectory: false)
    try encoder.encode(marker).write(to: markerURL, options: .atomic)
    try syncFile(markerURL)
    try syncDirectory(directory)
  }

  fileprivate static func artifactChecksum(
    planFingerprint: String,
    artifactsByTarget: [String: [PrivateHeaderGeneration.ArtifactPath]],
    opaquePaths: [PrivateHeaderGeneration.ArtifactPath]
  ) -> String {
    var lines = ["plan=\(planFingerprint)"]
    for targetID in artifactsByTarget.keys.sorted() {
      for path in artifactsByTarget[targetID, default: []].map(\.rawValue).sorted() {
        lines.append("target=\(targetID):\(path)")
      }
    }
    for path in opaquePaths.map(\.rawValue).sorted() {
      lines.append("opaque=\(path)")
    }
    let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  fileprivate func inventoryLegacyFiles(at root: URL) throws -> [PrivateHeaderGeneration
    .ArtifactPath]
  {
    let paths = try inventoryRegularFiles(at: root, allowHidden: true, allowedExtensions: nil)
      .map(\.path)
      .sorted { $0.rawValue < $1.rawValue }
    try Self.validatePortableOwnership(artifactsByTarget: [:], opaquePaths: paths)
    guard !paths.contains(where: { $0.rawValue == Self.markerName }) else {
      throw PublisherError.unexpectedItem(
        path: root.appendingPathComponent(Self.markerName).path,
        description: "legacy tree contains reserved generation marker path"
      )
    }
    return paths
  }

  fileprivate func inventoryRegularFiles(
    at root: URL,
    allowHidden: Bool,
    allowedExtensions: Set<String>?
  ) throws -> [(path: PrivateHeaderGeneration.ArtifactPath, url: URL)] {
    try inventoryItems(
      at: root,
      allowHidden: allowHidden,
      allowedExtensions: allowedExtensions
    ).compactMap { item in
      item.kind == .regular ? (item.path, item.url) : nil
    }
  }

  fileprivate func removeFinderMetadata(in root: URL) throws {
    var enumerationFailure: (URL, any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { url, error in
          enumerationFailure = (url, error)
          return false
        }
      )
    else {
      throw PublisherError.unexpectedItem(
        path: root.path,
        description: "could not enumerate directory"
      )
    }
    var metadataURLs: [URL] = []
    for case let url as URL in enumerator where url.lastPathComponent == ".DS_Store" {
      guard try itemKind(at: url) == .regular else {
        throw PublisherError.unexpectedItem(
          path: url.path,
          description: "Finder metadata path is not a regular file"
        )
      }
      metadataURLs.append(url)
    }
    if let (url, error) = enumerationFailure {
      throw PublisherError.unexpectedItem(
        path: url.path,
        description: "directory enumeration failed: \(error)"
      )
    }
    for url in metadataURLs {
      try FileManager.default.removeItem(at: url)
    }
  }

  fileprivate func inventoryItems(
    at root: URL,
    allowHidden: Bool,
    allowedExtensions: Set<String>?
  ) throws -> [InventoriedItem] {
    guard try itemKind(at: root) == .directory else {
      throw PublisherError.unexpectedItem(path: root.path, description: "expected directory")
    }
    var enumerationFailure: (URL, any Error)?
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: { url, error in
          enumerationFailure = (url, error)
          return false
        }
      )
    else {
      throw PublisherError.unexpectedItem(
        path: root.path, description: "could not enumerate directory")
    }
    let rootPath = root.standardizedFileURL.path
    var items: [InventoriedItem] = []
    for case let url as URL in enumerator {
      let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
      guard let kind = try itemKind(at: url) else {
        throw PublisherError.missingArtifact(url.path)
      }
      if url.lastPathComponent == ".DS_Store", kind == .regular {
        continue
      }
      if !allowHidden, relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
        throw PublisherError.unexpectedItem(path: url.path, description: "hidden staging payload")
      }
      switch kind {
      case .directory:
        items.append(
          InventoriedItem(
            path: try PrivateHeaderGeneration.ArtifactPath(relative),
            url: url,
            kind: kind
          ))
      case .symbolicLink:
        throw PublisherError.unexpectedItem(
          path: url.path, description: "symbolic links are not allowed")
      case .regular:
        if let allowedExtensions, !allowedExtensions.contains(url.pathExtension) {
          throw PublisherError.unexpectedItem(
            path: url.path, description: "unsupported regular file")
        }
        items.append(
          InventoriedItem(
            path: try PrivateHeaderGeneration.ArtifactPath(relative),
            url: url,
            kind: kind
          ))
      case .other:
        throw PublisherError.unexpectedItem(
          path: url.path, description: "unsupported filesystem item")
      }
    }
    if let (url, error) = enumerationFailure {
      throw PublisherError.unexpectedItem(
        path: url.path,
        description: "directory enumeration failed: \(error)"
      )
    }
    return items
  }

  fileprivate func artifactURL(
    _ artifact: PrivateHeaderGeneration.ArtifactPath,
    in root: URL
  ) throws -> URL {
    var url = root
    for component in artifact.rawValue.split(separator: "/") {
      url.appendPathComponent(String(component), isDirectory: false)
    }
    let standardizedRoot = root.standardizedFileURL.path
    let standardized = url.standardizedFileURL.path
    guard standardized.hasPrefix(standardizedRoot + "/") else {
      throw PublisherError.invalidManagedPath(artifact.rawValue)
    }
    return url
  }

  fileprivate func removeOwnedArtifact(
    _ artifact: PrivateHeaderGeneration.ArtifactPath,
    from root: URL
  ) throws {
    let url = try artifactURL(artifact, in: root)
    if try itemKind(at: url) != nil {
      try FileManager.default.removeItem(at: url)
    }
    var parent = url.deletingLastPathComponent()
    while parent.path != root.path {
      guard try itemKind(at: parent) == .directory else { break }
      guard try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty else { break }
      try FileManager.default.removeItem(at: parent)
      parent.deleteLastPathComponent()
    }
  }

  fileprivate func swapLegacyDirectoryForStableLink() throws {
    try ensureDirectoryWithoutSymlinks(legacyBackupsURL)
    let backup = legacyBackupsURL.appendingPathComponent(
      "legacy-\(UUID().uuidString.lowercased())",
      isDirectory: false
    )
    try createSymbolicLink(at: backup, destination: stableLinkDestination)
    #if canImport(Darwin)
      let result = renameatx_np(
        AT_FDCWD,
        stableURL.path,
        AT_FDCWD,
        backup.path,
        UInt32(RENAME_SWAP)
      )
      if result != 0 {
        let swapErrno = errno
        do {
          try FileManager.default.removeItem(at: backup)
        } catch let cleanupError {
          throw PublisherError.unexpectedItem(
            path: backup.path,
            description:
              "atomic swap failed with errno \(swapErrno), and temporary link cleanup failed: \(cleanupError)"
          )
        }
        if swapErrno == ENOTSUP || swapErrno == EINVAL {
          throw PublisherError.atomicSwapUnsupported(stableURL.path)
        }
        throw PublisherError.posix(
          operation: "renameatx_np(RENAME_SWAP)", path: stableURL.path, errno: swapErrno)
      }
    #else
      try FileManager.default.removeItem(at: backup)
      throw PublisherError.atomicSwapUnsupported(stableURL.path)
    #endif
    try syncDirectory(artifactBaseDirectory)
    try syncDirectory(legacyBackupsURL)
  }

  fileprivate func createSymbolicLink(at url: URL, destination: String) throws {
    let result = symlink(destination, url.path)
    guard result == 0 else {
      throw PublisherError.posix(operation: "symlink", path: url.path, errno: errno)
    }
  }

  fileprivate func atomicRename(from source: URL, to destination: URL) throws {
    guard rename(source.path, destination.path) == 0 else {
      throw PublisherError.posix(
        operation: "rename", path: "\(source.path) -> \(destination.path)", errno: errno)
    }
  }

  private func itemKind(at url: URL) throws -> ItemKind? {
    do {
      return try ManagedFileSystem.itemKind(at: url)
    } catch let error as ManagedFileSystem.Failure {
      throw Self.mapManagedFileSystemFailure(error)
    }
  }

  fileprivate static func mapManagedFileSystemFailure(_ error: ManagedFileSystem.Failure)
    -> PublisherError
  {
    switch error {
    case .invalidPath(let path):
      .invalidManagedPath(path)
    case .unexpectedKind(let path, let expected, let actual):
      .unexpectedItem(path: path, description: "expected \(expected), found \(actual.rawValue)")
    case .posix(let operation, let path, let code):
      .posix(operation: operation, path: path, errno: code)
    }
  }

  fileprivate func syncFile(_ url: URL) throws {
    try syncDescriptor(at: url, flags: O_RDONLY)
  }

  fileprivate func syncDirectory(_ url: URL) throws {
    try syncDescriptor(at: url, flags: O_RDONLY)
  }

  fileprivate func syncDescriptor(at url: URL, flags: Int32) throws {
    let descriptor = open(url.path, flags)
    guard descriptor >= 0 else {
      throw PublisherError.posix(operation: "open", path: url.path, errno: errno)
    }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw PublisherError.posix(operation: "fsync", path: url.path, errno: errno)
    }
  }
}
