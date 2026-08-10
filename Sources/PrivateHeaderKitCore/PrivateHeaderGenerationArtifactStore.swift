import Foundation

public extension PrivateHeaderGeneration {
    struct ArtifactCleanupResult: Equatable, Sendable {
        public let deletedArtifacts: [ArtifactPath]
        public let missingArtifacts: [ArtifactPath]
        public let prunedDirectories: [ArtifactPath]

        public init(
            deletedArtifacts: [ArtifactPath],
            missingArtifacts: [ArtifactPath],
            prunedDirectories: [ArtifactPath]
        ) {
            self.deletedArtifacts = deletedArtifacts
            self.missingArtifacts = missingArtifacts
            self.prunedDirectories = prunedDirectories
        }
    }

    enum ArtifactStoreError: Error, Equatable, CustomStringConvertible, Sendable {
        case nonFileArtifactRoot(String)
        case artifactPathEscapesRoot(artifactPath: ArtifactPath, artifactRoot: String, resolvedPath: String)
        case symbolicLinkInArtifactPath(artifactPath: ArtifactPath, symbolicLinkPath: String)
        case commitDestinationTypeMismatch(artifactPath: ArtifactPath, expected: String, actual: String)
        case symbolicLinkInStagingDirectory(String)
        case missingStagedArtifact(String)
        case stagedArtifactIsNotDirectory(String)
        case stagingDirectoryChanged(String)
        case artifactRootChanged(expected: String, actual: String)

        public var description: String {
            switch self {
            case .nonFileArtifactRoot(let artifactRoot):
                "artifact root must be a file URL: \(artifactRoot)"
            case .artifactPathEscapesRoot(let artifactPath, let artifactRoot, let resolvedPath):
                "artifact path escapes artifact root: \(artifactPath.rawValue) resolved to \(resolvedPath) outside \(artifactRoot)"
            case .symbolicLinkInArtifactPath(let artifactPath, let symbolicLinkPath):
                "artifact path contains a symbolic link: \(artifactPath.rawValue) traverses \(symbolicLinkPath)"
            case .commitDestinationTypeMismatch(let artifactPath, let expected, let actual):
                "commit destination has unexpected type: \(artifactPath.rawValue) expected \(expected), found \(actual)"
            case .symbolicLinkInStagingDirectory(let path):
                "staging directory contains a symbolic link: \(path)"
            case .missingStagedArtifact(let path):
                "staged artifact disappeared before commit: \(path)"
            case .stagedArtifactIsNotDirectory(let path):
                "staged artifact root is not a directory: \(path)"
            case .stagingDirectoryChanged(let path):
                "staging directory changed after commit preflight: \(path)"
            case .artifactRootChanged(let expected, let actual):
                "artifact root changed after commit preflight: expected \(expected), found \(actual)"
            }
        }
    }

    struct ArtifactStore: Sendable {
        public struct CommitPlan: Sendable {
            fileprivate let root: ArtifactRootURLs
            fileprivate let stagedSourceDirectory: URL
            fileprivate let artifactRoot: ArtifactPath
            fileprivate let entries: [CommitEntry]
        }

        public let artifactRoot: URL

        public init(artifactRoot: URL) {
            self.artifactRoot = artifactRoot
        }

        public func contains(
            _ artifact: ArtifactPath,
            fileManager: FileManager = .default
        ) throws -> Bool {
            let root = try Self.artifactRootURLs(for: artifactRoot)
            let url = try Self.artifactFileURL(for: artifact, root: root)
            return fileManager.fileExists(atPath: url.path)
        }

        @discardableResult
        public func cleanupManagedArtifacts(
            _ artifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> ArtifactCleanupResult {
            try Self.cleanupManagedArtifacts(
                in: artifactRoot,
                artifacts: artifacts,
                fileManager: fileManager
            )
        }

        public func prepareCommit(
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            fileManager: FileManager = .default
        ) throws -> CommitPlan {
            let root = try Self.artifactRootURLs(for: self.artifactRoot)
            let entries = try Self.commitEntries(
                stagedSourceDirectory: stagedSourceDirectory,
                artifactRoot: artifactRoot,
                fileManager: fileManager
            )
            let plan = CommitPlan(
                root: root,
                stagedSourceDirectory: stagedSourceDirectory.standardizedFileURL,
                artifactRoot: artifactRoot,
                entries: entries
            )
            try preflightCommit(plan, fileManager: fileManager)
            return plan
        }

        public func commit(
            _ plan: CommitPlan,
            fileManager: FileManager = .default
        ) throws {
            try preflightCommit(plan, fileManager: fileManager)

            for entry in plan.entries where entry.kind == .directory {
                let destination = try revalidate(
                    entry,
                    in: plan,
                    fileManager: fileManager
                )
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            }

            for entry in plan.entries where entry.kind == .file {
                let destination = try revalidate(
                    entry,
                    in: plan,
                    fileManager: fileManager
                )
                if try Self.artifactItemKind(at: destination, fileManager: fileManager) != nil {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: entry.source, to: destination)
            }
        }

        @discardableResult
        public static func cleanupManagedArtifacts(
            in artifactRoot: URL,
            artifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> ArtifactCleanupResult {
            let root = try artifactRootURLs(for: artifactRoot)
            let candidates = cleanupCandidates(manifestArtifacts: artifacts)
            let candidateSet = Set(candidates)
            let artifactURLs = try artifactFileURLs(
                for: candidates,
                root: root
            )
            var deletedArtifacts: [ArtifactPath] = []
            var missingArtifacts: [ArtifactPath] = []
            var prunedDirectories: [ArtifactPath] = []
            var prunedDirectorySet = Set<ArtifactPath>()

            for artifact in cleanupOperationOrder(candidates) {
                let artifactURL = artifactURLs[artifact]!

                guard let itemKind = try artifactItemKind(
                    at: artifactURL,
                    fileManager: fileManager
                ) else {
                    missingArtifacts.append(artifact)
                    continue
                }

                if itemKind == .directory {
                    guard try fileManager.contentsOfDirectory(atPath: artifactURL.path).isEmpty else {
                        continue
                    }
                }

                try fileManager.removeItem(at: artifactURL)
                deletedArtifacts.append(artifact)

                let pruned = try pruneEmptyParentDirectories(
                    afterDeleting: artifact,
                    root: root,
                    cleanupCandidates: candidateSet,
                    fileManager: fileManager
                )
                for directory in pruned where prunedDirectorySet.insert(directory).inserted {
                    prunedDirectories.append(directory)
                }
            }

            return ArtifactCleanupResult(
                deletedArtifacts: cleanupCandidates(manifestArtifacts: deletedArtifacts),
                missingArtifacts: cleanupCandidates(manifestArtifacts: missingArtifacts),
                prunedDirectories: cleanupCandidates(manifestArtifacts: prunedDirectories)
            )
        }

        public static func cleanupCandidates(
            manifestArtifacts: [ArtifactPath],
            attemptedArtifacts: [ArtifactPath] = []
        ) -> [ArtifactPath] {
            Array(Set(manifestArtifacts + attemptedArtifacts))
                .sorted { $0.rawValue < $1.rawValue }
        }

        fileprivate struct ArtifactRootURLs: Equatable, Sendable {
            let unresolved: URL
            let resolved: URL
        }

        fileprivate struct CommitEntry: Equatable, Sendable {
            let source: URL
            let artifact: ArtifactPath
            let kind: CommitEntryKind
        }

        fileprivate enum CommitEntryKind: Equatable, Sendable {
            case directory
            case file
        }

        private enum ArtifactItemKind: Equatable {
            case directory
            case symbolicLink
            case other
        }

        private static func artifactRootURLs(for artifactRoot: URL) throws -> ArtifactRootURLs {
            guard artifactRoot.isFileURL else {
                throw ArtifactStoreError.nonFileArtifactRoot(artifactRoot.absoluteString)
            }

            let unresolved = artifactRoot.standardizedFileURL
            return ArtifactRootURLs(
                unresolved: unresolved,
                resolved: unresolved.resolvingSymlinksInPath().standardizedFileURL
            )
        }

        private static func artifactFileURLs(
            for artifacts: [ArtifactPath],
            root: ArtifactRootURLs
        ) throws -> [ArtifactPath: URL] {
            var urls: [ArtifactPath: URL] = [:]
            for artifact in artifacts {
                urls[artifact] = try artifactFileURL(for: artifact, root: root)
            }
            return urls
        }

        private static func artifactFileURL(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs
        ) throws -> URL {
            var url = root.unresolved
            for component in artifact.rawValue.split(separator: "/", omittingEmptySubsequences: false) {
                url.appendPathComponent(String(component))
            }

            var resolvedURL = root.resolved
            for component in artifact.rawValue.split(separator: "/", omittingEmptySubsequences: false) {
                resolvedURL.appendPathComponent(String(component))
                resolvedURL = resolvedURL.standardizedFileURL.resolvingSymlinksInPath()
                guard isSameOrDescendant(resolvedURL, of: root.resolved) else {
                    throw ArtifactStoreError.artifactPathEscapesRoot(
                        artifactPath: artifact,
                        artifactRoot: root.resolved.path,
                        resolvedPath: resolvedURL.path
                    )
                }
            }

            return url
        }

        private static func commitEntries(
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            fileManager: FileManager
        ) throws -> [CommitEntry] {
            let sourceDirectory = stagedSourceDirectory.standardizedFileURL
            guard let sourceKind = try artifactItemKind(
                at: sourceDirectory,
                fileManager: fileManager
            ) else {
                throw ArtifactStoreError.missingStagedArtifact(sourceDirectory.path)
            }
            guard sourceKind != .symbolicLink else {
                throw ArtifactStoreError.symbolicLinkInStagingDirectory(sourceDirectory.path)
            }
            guard sourceKind == .directory else {
                throw ArtifactStoreError.stagedArtifactIsNotDirectory(sourceDirectory.path)
            }

            var entries = [
                CommitEntry(
                    source: sourceDirectory,
                    artifact: artifactRoot,
                    kind: .directory
                ),
            ]
            try appendCommitEntries(
                from: sourceDirectory,
                relativeComponents: [],
                artifactRoot: artifactRoot,
                fileManager: fileManager,
                entries: &entries
            )
            return entries.sorted {
                let leftDepth = pathDepth($0.artifact)
                let rightDepth = pathDepth($1.artifact)
                if leftDepth == rightDepth {
                    if $0.artifact == $1.artifact {
                        return $0.kind == .directory && $1.kind == .file
                    }
                    return $0.artifact.rawValue < $1.artifact.rawValue
                }
                return leftDepth < rightDepth
            }
        }

        private static func appendCommitEntries(
            from sourceDirectory: URL,
            relativeComponents: [String],
            artifactRoot: ArtifactPath,
            fileManager: FileManager,
            entries: inout [CommitEntry]
        ) throws {
            let children = try fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for child in children {
                guard let itemKind = try artifactItemKind(at: child, fileManager: fileManager) else {
                    throw ArtifactStoreError.missingStagedArtifact(child.path)
                }
                guard itemKind != .symbolicLink else {
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(child.path)
                }

                let components = relativeComponents + [child.lastPathComponent]
                let artifact = try ArtifactPath(
                    ([artifactRoot.rawValue] + components).joined(separator: "/")
                )
                let kind: CommitEntryKind = itemKind == .directory ? .directory : .file
                entries.append(
                    CommitEntry(
                        source: child,
                        artifact: artifact,
                        kind: kind
                    )
                )

                if kind == .directory {
                    try appendCommitEntries(
                        from: child,
                        relativeComponents: components,
                        artifactRoot: artifactRoot,
                        fileManager: fileManager,
                        entries: &entries
                    )
                }
            }
        }

        private static func commitDestinationURL(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> URL {
            var url = root.unresolved
            var resolvedURL = root.resolved
            for component in artifact.rawValue.split(separator: "/", omittingEmptySubsequences: false) {
                url.appendPathComponent(String(component))
                resolvedURL.appendPathComponent(String(component))
                if try artifactItemKind(at: url, fileManager: fileManager) == .symbolicLink {
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: url.path
                    )
                }
            }
            resolvedURL = resolvedURL.standardizedFileURL
            guard isSameOrDescendant(resolvedURL, of: root.resolved) else {
                throw ArtifactStoreError.artifactPathEscapesRoot(
                    artifactPath: artifact,
                    artifactRoot: root.resolved.path,
                    resolvedPath: resolvedURL.path
                )
            }
            return url
        }

        private func preflightCommit(
            _ plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            try validateArtifactRoot(of: plan)
            let currentEntries = try Self.commitEntries(
                stagedSourceDirectory: plan.stagedSourceDirectory,
                artifactRoot: plan.artifactRoot,
                fileManager: fileManager
            )
            guard currentEntries == plan.entries else {
                throw ArtifactStoreError.stagingDirectoryChanged(
                    plan.stagedSourceDirectory.path
                )
            }

            for entry in plan.entries {
                let destination = try Self.commitDestinationURL(
                    for: entry.artifact,
                    root: plan.root,
                    fileManager: fileManager
                )
                try Self.validateCommitDestination(
                    destination,
                    for: entry,
                    fileManager: fileManager
                )
            }
        }

        private func revalidate(
            _ entry: CommitEntry,
            in plan: CommitPlan,
            fileManager: FileManager
        ) throws -> URL {
            try validateArtifactRoot(of: plan)
            guard let sourceKind = try Self.artifactItemKind(
                at: entry.source,
                fileManager: fileManager
            ) else {
                throw ArtifactStoreError.missingStagedArtifact(entry.source.path)
            }
            guard sourceKind != .symbolicLink else {
                throw ArtifactStoreError.symbolicLinkInStagingDirectory(entry.source.path)
            }
            let expectedSourceKind: ArtifactItemKind = entry.kind == .directory ? .directory : .other
            guard sourceKind == expectedSourceKind else {
                throw ArtifactStoreError.stagingDirectoryChanged(
                    plan.stagedSourceDirectory.path
                )
            }

            let destination = try Self.commitDestinationURL(
                for: entry.artifact,
                root: plan.root,
                fileManager: fileManager
            )
            try Self.validateCommitDestination(
                destination,
                for: entry,
                fileManager: fileManager
            )
            return destination
        }

        private func validateArtifactRoot(of plan: CommitPlan) throws {
            let current = try Self.artifactRootURLs(for: artifactRoot)
            guard current == plan.root else {
                throw ArtifactStoreError.artifactRootChanged(
                    expected: plan.root.resolved.path,
                    actual: current.resolved.path
                )
            }
        }

        private static func validateCommitDestination(
            _ destination: URL,
            for entry: CommitEntry,
            fileManager: FileManager
        ) throws {
            guard let existingKind = try artifactItemKind(at: destination, fileManager: fileManager) else {
                return
            }

            switch (entry.kind, existingKind) {
            case (.directory, .directory), (.file, .other):
                return
            case (.directory, .symbolicLink), (.file, .symbolicLink):
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: entry.artifact,
                    symbolicLinkPath: destination.path
                )
            case (.directory, .other):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: entry.artifact,
                    expected: "directory",
                    actual: "file"
                )
            case (.file, .directory):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: entry.artifact,
                    expected: "file",
                    actual: "directory"
                )
            }
        }

        private static func artifactItemKind(
            at url: URL,
            fileManager: FileManager
        ) throws -> ArtifactItemKind? {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let fileType = attributes[.type] as? FileAttributeType
                if fileType == .typeDirectory {
                    return .directory
                }
                if fileType == .typeSymbolicLink {
                    return .symbolicLink
                }
                return .other
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain,
                   nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue
                {
                    return nil
                }
                throw error
            }
        }

        private static func cleanupOperationOrder(_ artifacts: [ArtifactPath]) -> [ArtifactPath] {
            artifacts.sorted {
                let leftDepth = pathDepth($0)
                let rightDepth = pathDepth($1)
                if leftDepth == rightDepth {
                    return $0.rawValue < $1.rawValue
                }
                return leftDepth > rightDepth
            }
        }

        private static func pathDepth(_ artifact: ArtifactPath) -> Int {
            artifact.rawValue.split(separator: "/").count
        }

        private static func pruneEmptyParentDirectories(
            afterDeleting artifact: ArtifactPath,
            root: ArtifactRootURLs,
            cleanupCandidates: Set<ArtifactPath>,
            fileManager: FileManager
        ) throws -> [ArtifactPath] {
            var prunedDirectories: [ArtifactPath] = []

            for parent in try parentDirectories(for: artifact) {
                if cleanupCandidates.contains(parent) {
                    break
                }

                let parentURL = try artifactFileURL(for: parent, root: root)
                guard try artifactItemKind(at: parentURL, fileManager: fileManager) == .directory
                else {
                    continue
                }

                guard try fileManager.contentsOfDirectory(atPath: parentURL.path).isEmpty else {
                    break
                }

                try fileManager.removeItem(at: parentURL)
                prunedDirectories.append(parent)
            }

            return prunedDirectories
        }

        private static func parentDirectories(for artifact: ArtifactPath) throws -> [ArtifactPath] {
            let components = artifact.rawValue.split(separator: "/").map(String.init)
            guard components.count > 1 else {
                return []
            }

            return try stride(from: components.count - 1, through: 1, by: -1).map { count in
                try ArtifactPath(components.prefix(count).joined(separator: "/"))
            }
        }

        private static func isSameOrDescendant(_ url: URL, of root: URL) -> Bool {
            let path = url.path
            let rootPath = root.path
            if path == rootPath {
                return true
            }
            if rootPath == "/" {
                return path.hasPrefix("/")
            }
            return path.hasPrefix(rootPath + "/")
        }
    }
}
