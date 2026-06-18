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

        public var description: String {
            switch self {
            case .nonFileArtifactRoot(let artifactRoot):
                "artifact root must be a file URL: \(artifactRoot)"
            case .artifactPathEscapesRoot(let artifactPath, let artifactRoot, let resolvedPath):
                "artifact path escapes artifact root: \(artifactPath.rawValue) resolved to \(resolvedPath) outside \(artifactRoot)"
            }
        }
    }

    struct ArtifactStore: Sendable {
        public let artifactRoot: URL

        public init(artifactRoot: URL) {
            self.artifactRoot = artifactRoot
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

        private struct ArtifactRootURLs {
            let unresolved: URL
            let resolved: URL
        }

        private enum ArtifactItemKind {
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
