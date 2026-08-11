import CryptoKit
import Foundation

extension PrivateHeaderGeneration {
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
        case artifactRootTypeMismatch(path: String, actual: String)
        case nonFileStagingDirectory(String)
        case artifactPathEscapesRoot(
            artifactPath: ArtifactPath, artifactRoot: String, resolvedPath: String)
        case symbolicLinkInArtifactPath(artifactPath: ArtifactPath, symbolicLinkPath: String)
        case cleanupParentTypeMismatch(
            artifactPath: ArtifactPath, parentPath: String, actual: String)
        case cleanupDirectoryNotEmpty(artifactPath: ArtifactPath, directoryPath: String)
        case commitDestinationTypeMismatch(
            artifactPath: ArtifactPath, expected: String, actual: String)
        case symbolicLinkInStagingDirectory(String)
        case missingStagedArtifact(String)
        case stagedArtifactIsNotDirectory(String)
        case stagedArtifactIsNotRegularFile(String)
        case stagedSourceOutsideStagingDirectory(stagedSource: String, stagingDirectory: String)
        case artifactPathOutsideCommitRoot(artifactPath: ArtifactPath, artifactRoot: ArtifactPath)
        case commitSourceDestinationOverlap(source: String, destination: String)
        case commitDestinationCollision(first: ArtifactPath, second: ArtifactPath)
        case destinationVolumeCaseSensitivityUnavailable(String)
        case destinationVolumeCaseSensitivityChanged(root: String, expected: Bool, actual: Bool)
        case stagingDirectoryChanged(String)
        case artifactRootChanged(expected: String, actual: String)
        case artifactContentChanged(artifactPath: ArtifactPath, path: String)
        case artifactInventoryFailed(path: String, description: String)
        case invalidArtifactDigestSet(String)
        case replacementVolumeMismatch(liveRoot: String, transactionRoot: String)
        case invalidReplacementManifest(String)
        case cleanupSynchronizationFailed(primary: String, synchronization: String)
        case replacementPreparationCleanupFailed(primary: String, cleanup: String)
        case replacementRollbackFailed(primary: String, rollback: String)

        public var description: String {
            switch self {
            case .nonFileArtifactRoot(let artifactRoot):
                "artifact root must be a file URL: \(artifactRoot)"
            case .artifactRootTypeMismatch(let path, let actual):
                "artifact root must be a directory or missing: \(path), found \(actual)"
            case .nonFileStagingDirectory(let stagingDirectory):
                "staging directory must be a file URL: \(stagingDirectory)"
            case .artifactPathEscapesRoot(let artifactPath, let artifactRoot, let resolvedPath):
                "artifact path escapes artifact root: \(artifactPath.rawValue) resolved to \(resolvedPath) outside \(artifactRoot)"
            case .symbolicLinkInArtifactPath(let artifactPath, let symbolicLinkPath):
                "artifact path contains a symbolic link: \(artifactPath.rawValue) traverses \(symbolicLinkPath)"
            case .cleanupParentTypeMismatch(let artifactPath, let parentPath, let actual):
                "cleanup artifact parent has unexpected type: \(artifactPath.rawValue) traverses \(parentPath), found \(actual)"
            case .cleanupDirectoryNotEmpty(let artifactPath, let directoryPath):
                "cleanup artifact directory is not empty: \(artifactPath.rawValue) at \(directoryPath)"
            case .commitDestinationTypeMismatch(let artifactPath, let expected, let actual):
                "commit destination has unexpected type: \(artifactPath.rawValue) expected \(expected), found \(actual)"
            case .symbolicLinkInStagingDirectory(let path):
                "staging directory contains a symbolic link: \(path)"
            case .missingStagedArtifact(let path):
                "staged artifact disappeared before commit: \(path)"
            case .stagedArtifactIsNotDirectory(let path):
                "staged artifact path is not a directory: \(path)"
            case .stagedArtifactIsNotRegularFile(let path):
                "staged artifact is not a regular file: \(path)"
            case .stagedSourceOutsideStagingDirectory(let stagedSource, let stagingDirectory):
                "staged source is outside staging directory: \(stagedSource) is not under \(stagingDirectory)"
            case .artifactPathOutsideCommitRoot(let artifactPath, let artifactRoot):
                "artifact path is outside commit root: \(artifactPath.rawValue) is not under \(artifactRoot.rawValue)"
            case .commitSourceDestinationOverlap(let source, let destination):
                "commit source and destination overlap: \(source) and \(destination)"
            case .commitDestinationCollision(let first, let second):
                "commit destinations collide: \(first.rawValue) and \(second.rawValue)"
            case .destinationVolumeCaseSensitivityUnavailable(let root):
                "destination volume case sensitivity is unavailable: \(root)"
            case .destinationVolumeCaseSensitivityChanged(let root, let expected, let actual):
                "destination volume case sensitivity changed: \(root) expected \(expected), found \(actual)"
            case .stagingDirectoryChanged(let path):
                "staging directory changed after commit preflight: \(path)"
            case .artifactRootChanged(let expected, let actual):
                "artifact root changed after commit preflight: expected \(expected), found \(actual)"
            case .artifactContentChanged(let artifactPath, let path):
                "artifact contents changed after replacement preparation: \(artifactPath.rawValue) at \(path)"
            case .artifactInventoryFailed(let path, let description):
                "artifact inventory failed at \(path): \(description)"
            case .invalidArtifactDigestSet(let description):
                "invalid artifact digest set: \(description)"
            case .replacementVolumeMismatch(let liveRoot, let transactionRoot):
                "artifact replacement requires one filesystem volume: \(liveRoot) and \(transactionRoot)"
            case .invalidReplacementManifest(let message):
                "invalid artifact replacement manifest: \(message)"
            case .cleanupSynchronizationFailed(let primary, let synchronization):
                "artifact cleanup failed: \(primary); synchronizing prior deletions also failed: \(synchronization)"
            case .replacementPreparationCleanupFailed(let primary, let cleanup):
                "artifact replacement preparation failed: \(primary); cleanup also failed: \(cleanup)"
            case .replacementRollbackFailed(let primary, let rollback):
                "artifact replacement failed: \(primary); rollback also failed: \(rollback)"
            }
        }
    }

    struct ArtifactStore: Sendable {
        private static let replacementManifestVersion = 1

        internal struct CommitPlan: Sendable {
            fileprivate let root: ArtifactRootURLs
            fileprivate let stagingDirectory: URL
            fileprivate let resolvedStagingDirectory: URL
            fileprivate let stagedSourceDirectory: URL
            fileprivate let resolvedStagedSourceDirectory: URL
            fileprivate let artifactRoot: ArtifactPath
            fileprivate let artifacts: [ArtifactPath]
            fileprivate let entries: [CommitEntry]
            fileprivate let destinationVolumeSupportsCaseSensitiveNames: Bool
        }

        internal struct Replacement: Sendable {
            fileprivate let directory: URL
            fileprivate let incomingRoot: URL
            fileprivate let backupRoot: URL
            fileprivate let restoreRoot: URL
            internal let runID: PrivateHeaderGeneration.RunID
            internal let targetID: String
            fileprivate let artifactRoot: ArtifactPath
            internal let incomingArtifacts: [ArtifactPath]
            fileprivate let mutationArtifacts: [ArtifactPath]
            fileprivate let mutationPathKinds: [ArtifactPath: MutationPathKind]
            fileprivate let backedUpArtifacts: [ArtifactPath]
            fileprivate let incomingDigests: [ArtifactPath: String]
            fileprivate let backedUpDigests: [ArtifactPath: String]
            fileprivate let artifactRootIdentity: FileSystemIdentity

            internal var artifactDigests: [ArtifactPath: String] { incomingDigests }
        }

        fileprivate enum MutationPathKind: String, Codable, Equatable, Sendable {
            case missing
            case regularFile
            case directory
            case occupiedByRegularFile
        }

        private struct PreparedMutation {
            let backedUpArtifacts: [ArtifactPath]
            let pathKinds: [ArtifactPath: MutationPathKind]
        }

        fileprivate struct FileSystemIdentity: Codable, Equatable, Sendable {
            let device: UInt64
            let inode: UInt64

            var description: String { "\(device):\(inode)" }
        }

        private struct ReplacementManifest: Codable {
            let version: Int
            let runID: String
            let targetID: String
            let artifactRoot: String
            let incomingArtifacts: [String]
            let mutationArtifacts: [String]
            let mutationPathKinds: [String: MutationPathKind]
            let backedUpArtifacts: [String]
            let incomingDigests: [String: String]
            let backedUpDigests: [String: String]
            let artifactRootIdentity: FileSystemIdentity
        }

        private struct ReplacementManifestVersion: Decodable {
            let version: Int
        }

        private struct RestorationPlan {
            let sourceRoot: ArtifactRootURLs
            let destinationRoot: ArtifactRootURLs
            let entries: [RestorationEntry]
        }

        private struct RestorationEntry {
            let artifact: ArtifactPath
            let source: URL
            let destination: URL
            let digest: String
        }

        private struct IncomingRollbackPlan {
            let root: ArtifactRootURLs
            let stagedRoot: ArtifactRootURLs
            let installedArtifacts: [ArtifactPath]
        }

        private struct RollbackPlan {
            let incoming: IncomingRollbackPlan
            let replacementDirectories: [ArtifactPath]
            let restoration: RestorationPlan?
        }

        public let artifactRoot: URL

        public init(artifactRoot: URL) {
            self.artifactRoot = artifactRoot
        }

        public func contains(
            _ artifact: ArtifactPath,
            fileManager: FileManager = .default
        ) throws -> Bool {
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            switch try Self.inspectArtifactPath(
                artifact,
                root: root,
                fileManager: fileManager
            ) {
            case .leaf(_, .some(.regularFile)):
                return true
            case .missingParent, .occupiedParent, .symbolicLinkParent, .leaf:
                return false
            }
        }

        internal func inventoryRegularArtifacts(
            fileManager: FileManager = .default
        ) throws -> [ArtifactPath] {
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            guard
                try Self.artifactItemKind(
                    at: root.unresolved,
                    fileManager: fileManager
                ) == .directory
            else {
                throw ArtifactStoreError.artifactRootTypeMismatch(
                    path: root.unresolved.path,
                    actual: "missing"
                )
            }
            var enumerationFailure: (URL, any Error)?
            guard
                let enumerator = fileManager.enumerator(
                    at: root.unresolved,
                    includingPropertiesForKeys: nil,
                    options: [],
                    errorHandler: { url, error in
                        enumerationFailure = (url, error)
                        return false
                    }
                )
            else {
                throw ArtifactStoreError.artifactInventoryFailed(
                    path: root.unresolved.path,
                    description: "could not enumerate directory"
                )
            }

            let rootPath = root.unresolved.path
            var artifacts: [ArtifactPath] = []
            for case let url as URL in enumerator {
                let standardized = url.standardizedFileURL
                guard standardized.path.hasPrefix(rootPath + "/") else {
                    throw ArtifactStoreError.artifactInventoryFailed(
                        path: standardized.path,
                        description: "enumerated item escapes artifact root"
                    )
                }
                let relativePath = String(standardized.path.dropFirst(rootPath.count + 1))
                let artifact = try ArtifactPath(relativePath)
                guard
                    let kind = try Self.artifactItemKind(
                        at: standardized,
                        fileManager: fileManager
                    )
                else {
                    throw ArtifactStoreError.artifactInventoryFailed(
                        path: standardized.path,
                        description: "item disappeared during enumeration"
                    )
                }
                switch kind {
                case .directory:
                    continue
                case .regularFile:
                    if standardized.lastPathComponent == ".DS_Store" { continue }
                    artifacts.append(artifact)
                case .symbolicLink:
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: standardized.path
                    )
                case .other:
                    throw ArtifactStoreError.artifactInventoryFailed(
                        path: standardized.path,
                        description: "unsupported filesystem item"
                    )
                }
            }
            if let (url, error) = enumerationFailure {
                throw ArtifactStoreError.artifactInventoryFailed(
                    path: url.path,
                    description: "directory enumeration failed: \(error)"
                )
            }
            return artifacts.sorted { $0.rawValue < $1.rawValue }
        }

        internal func artifactsExcludingEquivalentPaths(
            _ candidates: [ArtifactPath],
            retainedArtifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> [ArtifactPath] {
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            let volumeSupportsCaseSensitiveNames =
                try Self.destinationVolumeSupportsCaseSensitiveNames(
                    for: root,
                    fileManager: fileManager
                )
            let retainedKeys = Set(retainedArtifacts.map {
                Self.artifactPathIdentityKey(
                    for: $0,
                    volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
                )
            })
            return Self.cleanupCandidates(
                manifestArtifacts: candidates.filter {
                    !retainedKeys.contains(
                        Self.artifactPathIdentityKey(
                            for: $0,
                            volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
                        )
                    )
                }
            )
        }

        internal func artifactsMatchDigests(
            _ artifacts: [ArtifactPath],
            digests: [ArtifactPath: String],
            fileManager: FileManager = .default
        ) throws -> Bool {
            guard !digests.isEmpty else { return false }
            guard Set(digests.keys) == Set(artifacts), digests.values.allSatisfy(Self.isValidSHA256)
            else {
                throw ArtifactStoreError.invalidArtifactDigestSet(
                    "digest paths or values do not match the target artifact set"
                )
            }
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            for artifact in artifacts {
                guard
                    case .leaf(let url, .some(.regularFile)) = try Self.inspectArtifactPath(
                        artifact,
                        root: root,
                        fileManager: fileManager
                    ),
                    let expectedDigest = digests[artifact]
                else {
                    return false
                }
                guard try Self.sha256(of: url) == expectedDigest else { return false }
            }
            return true
        }

        internal func validateExistingArtifacts(
            _ artifacts: [ArtifactPath],
            digests: [ArtifactPath: String],
            fileManager: FileManager = .default
        ) throws {
            guard Set(digests.keys) == Set(artifacts), digests.values.allSatisfy(Self.isValidSHA256)
            else {
                throw ArtifactStoreError.invalidArtifactDigestSet(
                    "digest paths or values do not match the artifact set"
                )
            }
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            for artifact in artifacts {
                let inspection = try Self.inspectArtifactPath(
                    artifact,
                    root: root,
                    fileManager: fileManager
                )
                switch inspection {
                case .missingParent, .leaf(_, nil):
                    continue
                case .leaf(let url, .some(.regularFile)):
                    guard let expectedDigest = digests[artifact],
                        try Self.sha256(of: url) == expectedDigest
                    else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: url.path
                        )
                    }
                case .symbolicLinkParent(let url):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: url.path
                    )
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: artifact,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .leaf(_, .some(let kind)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: artifact,
                        expected: "regular file or missing",
                        actual: Self.artifactItemKindDescription(kind)
                    )
                }
            }
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

        internal func restoreArtifact(
            _ artifact: ArtifactPath,
            from source: URL,
            stagingDirectory: URL,
            synchronizeExistingArtifact: Bool,
            fileManager: FileManager = .default
        ) throws {
            guard
                try Self.artifactItemKind(at: source, fileManager: fileManager) == .regularFile
            else {
                throw ArtifactStoreError.stagedArtifactIsNotRegularFile(source.path)
            }
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            let destination = Self.artifactURL(artifact, under: root.unresolved)
            if let existing = try Self.restorableArtifactURL(
                artifact,
                root: root,
                fileManager: fileManager
            ) {
                if fileManager.contentsEqual(atPath: source.path, andPath: existing.path) {
                    if synchronizeExistingArtifact {
                        try ManagedFileSystem.syncFile(existing)
                        try ManagedFileSystem.syncDirectory(
                            existing.deletingLastPathComponent().standardizedFileURL
                        )
                    }
                    return
                }
            }

            let destinationDirectory = destination.deletingLastPathComponent().standardizedFileURL
            try ManagedFileSystem.ensureRealDirectory(destinationDirectory)
            let refreshedRoot = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            guard refreshedRoot == root else {
                throw ArtifactStoreError.artifactRootChanged(
                    expected: root.resolved.path,
                    actual: refreshedRoot.resolved.path
                )
            }
            if let existing = try Self.restorableArtifactURL(
                artifact,
                root: refreshedRoot,
                fileManager: fileManager
            ) {
                if fileManager.contentsEqual(atPath: source.path, andPath: existing.path) {
                    if synchronizeExistingArtifact {
                        try ManagedFileSystem.syncFile(existing)
                        try ManagedFileSystem.syncDirectory(
                            existing.deletingLastPathComponent().standardizedFileURL
                        )
                    }
                    return
                }
            }

            guard try ManagedFileSystem.itemKind(at: stagingDirectory) == .directory else {
                throw ArtifactStoreError.stagedArtifactIsNotDirectory(stagingDirectory.path)
            }
            let temporary = stagingDirectory.appendingPathComponent(
                "artifact-\(UUID().uuidString.lowercased())",
                isDirectory: false
            )
            do {
                try fileManager.copyItem(at: source, to: temporary)
                try ManagedFileSystem.syncFile(temporary)
                try ManagedFileSystem.atomicRename(from: temporary, to: destination)
                try ManagedFileSystem.syncFile(destination)
                try ManagedFileSystem.syncDirectory(destinationDirectory)
                try ManagedFileSystem.syncDirectory(stagingDirectory)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
            guard fileManager.contentsEqual(atPath: source.path, andPath: destination.path) else {
                throw ArtifactStoreError.artifactContentChanged(
                    artifactPath: artifact,
                    path: destination.path
                )
            }
        }

        private static func restorableArtifactURL(
            _ artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> URL? {
            switch try inspectArtifactPath(
                artifact,
                root: root,
                fileManager: fileManager
            ) {
            case .missingParent, .leaf(_, nil):
                return nil
            case .leaf(let existing, .some(.regularFile)):
                return existing
            case .occupiedParent(let path, let kind):
                throw ArtifactStoreError.cleanupParentTypeMismatch(
                    artifactPath: artifact,
                    parentPath: path.path,
                    actual: artifactItemKindDescription(kind)
                )
            case .symbolicLinkParent(let path):
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: artifact,
                    symbolicLinkPath: path.path
                )
            case .leaf(let path, .some(.symbolicLink)):
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: artifact,
                    symbolicLinkPath: path.path
                )
            case .leaf(_, .some(.directory)):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: artifact,
                    expected: "regular file or missing",
                    actual: "directory"
                )
            case .leaf(_, .some(.other)):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: artifact,
                    expected: "regular file or missing",
                    actual: "special file"
                )
            }
        }

        internal func prepareCommit(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            artifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> CommitPlan {
            let plan = try makeCommitPlan(
                stagingDirectory: stagingDirectory,
                stagedSourceDirectory: stagedSourceDirectory,
                artifactRoot: artifactRoot,
                artifacts: artifacts,
                fileManager: fileManager
            )
            try preflightCommit(plan, fileManager: fileManager)
            return plan
        }

        private func makeCommitPlan(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            artifacts: [ArtifactPath],
            fileManager: FileManager
        ) throws -> CommitPlan {
            let root = try Self.artifactRootURLs(
                for: self.artifactRoot,
                fileManager: fileManager
            )
            let destinationVolumeSupportsCaseSensitiveNames =
                try Self
                .destinationVolumeSupportsCaseSensitiveNames(
                    for: root,
                    fileManager: fileManager
                )
            let artifacts = artifacts.sorted { $0.rawValue < $1.rawValue }
            try Self.validateDestinationCollisions(artifacts)
            let entries = try Self.commitEntries(
                stagingDirectory: stagingDirectory,
                stagedSourceDirectory: stagedSourceDirectory,
                artifactRoot: artifactRoot,
                artifacts: artifacts,
                fileManager: fileManager
            )
            let plan = CommitPlan(
                root: root,
                stagingDirectory: stagingDirectory.standardizedFileURL,
                resolvedStagingDirectory:
                    stagingDirectory
                    .resolvingSymlinksInPath()
                    .standardizedFileURL,
                stagedSourceDirectory: stagedSourceDirectory.standardizedFileURL,
                resolvedStagedSourceDirectory:
                    stagedSourceDirectory
                    .resolvingSymlinksInPath()
                    .standardizedFileURL,
                artifactRoot: artifactRoot,
                artifacts: artifacts,
                entries: entries,
                destinationVolumeSupportsCaseSensitiveNames:
                    destinationVolumeSupportsCaseSensitiveNames
            )
            return plan
        }

        internal func commit(
            _ plan: CommitPlan,
            fileManager: FileManager = .default
        ) throws {
            try write(plan, preservingSources: false, fileManager: fileManager)
        }

        internal func copy(
            _ plan: CommitPlan,
            fileManager: FileManager = .default
        ) throws {
            try write(plan, preservingSources: true, fileManager: fileManager)
        }

        internal func prepareReplacement(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            artifacts: [ArtifactPath],
            removing artifactsToRemove: [ArtifactPath],
            runID: PrivateHeaderGeneration.RunID,
            targetID: String,
            at transactionDirectory: URL,
            fileManager: FileManager = .default,
            exclusiveRename: (URL, URL) throws -> Void =
                ManagedFileSystem.atomicRenameExclusively
        ) throws -> Replacement {
            let plan = try makeCommitPlan(
                stagingDirectory: stagingDirectory,
                stagedSourceDirectory: stagedSourceDirectory,
                artifactRoot: artifactRoot,
                artifacts: artifacts,
                fileManager: fileManager
            )
            try preflightCommitInputs(plan, fileManager: fileManager)
            let artifactRootIdentity = try Self.directoryIdentity(
                at: plan.root.unresolved,
                fileManager: fileManager
            )
            let incomingArtifacts = plan.artifacts.sorted { $0.rawValue < $1.rawValue }
            let mutationArtifacts = Self.cleanupCandidates(
                manifestArtifacts: artifactsToRemove,
                attemptedArtifacts: incomingArtifacts
            )

            let directory = transactionDirectory.standardizedFileURL
            let incomingRoot = directory.appendingPathComponent("incoming", isDirectory: true)
            let backupRoot = directory.appendingPathComponent("backup", isDirectory: true)
            let restoreRoot = directory.appendingPathComponent("restore", isDirectory: true)
            let durableAncestor = try Self.nearestExistingRealDirectory(
                startingAt: directory.deletingLastPathComponent(),
                fileManager: fileManager
            )
            do {
                guard try Self.artifactItemKind(at: directory, fileManager: fileManager) == nil else {
                    throw ArtifactStoreError.invalidReplacementManifest(
                        "transaction directory already exists at \(directory.path)"
                    )
                }
                try ManagedFileSystem.ensureRealDirectory(
                    directory.deletingLastPathComponent()
                )
                try fileManager.createDirectory(
                    at: incomingRoot,
                    withIntermediateDirectories: true
                )
                try fileManager.createDirectory(
                    at: backupRoot,
                    withIntermediateDirectories: true
                )
                try fileManager.createDirectory(
                    at: restoreRoot,
                    withIntermediateDirectories: true
                )
                try Self.validateReplacementVolumes(
                    liveRoot: plan.root.unresolved,
                    liveRootIdentity: artifactRootIdentity,
                    transactionRoots: [incomingRoot, restoreRoot],
                    fileManager: fileManager
                )
                try Self.validateExclusiveRenameSupport(
                    in: directory,
                    fileManager: fileManager,
                    exclusiveRename: exclusiveRename
                )

                let incomingStore = ArtifactStore(artifactRoot: incomingRoot)
                let incomingPlan = try incomingStore.prepareCommit(
                    stagingDirectory: plan.stagingDirectory,
                    stagedSourceDirectory: plan.stagedSourceDirectory,
                    artifactRoot: plan.artifactRoot,
                    artifacts: incomingArtifacts,
                    fileManager: fileManager
                )
                try incomingStore.copy(incomingPlan, fileManager: fileManager)
                let incomingDigests = try Self.artifactDigests(
                    for: incomingArtifacts,
                    under: incomingRoot,
                    fileManager: fileManager
                )

                let preparedMutation = try prepareMutation(
                    mutationArtifacts,
                    preferring: artifactsToRemove,
                    from: plan.root,
                    to: backupRoot,
                    volumeSupportsCaseSensitiveNames:
                        plan.destinationVolumeSupportsCaseSensitiveNames,
                    fileManager: fileManager
                )
                let backedUpArtifacts = preparedMutation.backedUpArtifacts
                let backedUpDigests = try Self.artifactDigests(
                    for: backedUpArtifacts,
                    under: backupRoot,
                    fileManager: fileManager
                )
                try Self.copyArtifacts(
                    backedUpArtifacts,
                    from: backupRoot,
                    to: restoreRoot,
                    expectedDigests: backedUpDigests,
                    fileManager: fileManager
                )
                try Self.syncTree(at: incomingRoot, fileManager: fileManager)
                try Self.syncTree(at: backupRoot, fileManager: fileManager)
                try Self.syncTree(at: restoreRoot, fileManager: fileManager)
                let replacement = Replacement(
                    directory: directory,
                    incomingRoot: incomingRoot,
                    backupRoot: backupRoot,
                    restoreRoot: restoreRoot,
                    runID: runID,
                    targetID: targetID,
                    artifactRoot: plan.artifactRoot,
                    incomingArtifacts: incomingArtifacts,
                    mutationArtifacts: mutationArtifacts,
                    mutationPathKinds: preparedMutation.pathKinds,
                    backedUpArtifacts: backedUpArtifacts,
                    incomingDigests: incomingDigests,
                    backedUpDigests: backedUpDigests,
                    artifactRootIdentity: artifactRootIdentity
                )
                try writeManifest(for: replacement, fileManager: fileManager)
                try Self.syncDirectoryChain(
                    from: directory,
                    through: durableAncestor,
                    fileManager: fileManager
                )
                return replacement
            } catch {
                let primary = error
                do {
                    if try Self.artifactItemKind(at: directory, fileManager: fileManager) != nil {
                        try fileManager.removeItem(at: directory)
                    }
                } catch {
                    throw ArtifactStoreError.replacementPreparationCleanupFailed(
                        primary: String(describing: primary),
                        cleanup: String(describing: error)
                    )
                }
                throw primary
            }
        }

        internal func applyReplacement(
            _ replacement: Replacement,
            fileManager: FileManager = .default
        ) throws {
            try preflightReplacementApply(replacement, fileManager: fileManager)
            try markReplacementApplyStarted(replacement, fileManager: fileManager)
            do {
                _ = try cleanupManagedArtifacts(
                    replacement.backedUpArtifacts,
                    fileManager: fileManager
                )
                let incomingSourceDirectory = Self.artifactURL(
                    replacement.artifactRoot,
                    under: replacement.incomingRoot
                )
                let incomingPlan = try prepareCommit(
                    stagingDirectory: replacement.incomingRoot,
                    stagedSourceDirectory: incomingSourceDirectory,
                    artifactRoot: replacement.artifactRoot,
                    artifacts: replacement.incomingArtifacts,
                    fileManager: fileManager
                )
                try applyPreparedIncoming(incomingPlan, fileManager: fileManager)
                try synchronizeReplacementMutations(
                    replacement,
                    sourceRoot: replacement.incomingRoot,
                    sourceArtifacts: replacement.incomingArtifacts,
                    fileManager: fileManager
                )
            } catch {
                let primary = error
                do {
                    try rollbackReplacement(replacement, fileManager: fileManager)
                } catch {
                    throw ArtifactStoreError.replacementRollbackFailed(
                        primary: String(describing: primary),
                        rollback: String(describing: error)
                    )
                }
                throw primary
            }
        }

        internal func rollbackReplacement(
            _ replacement: Replacement,
            fileManager: FileManager = .default
        ) throws {
            guard try replacementApplyHasStarted(replacement, fileManager: fileManager) else {
                return
            }
            try validateReplacementArtifactRoot(replacement, fileManager: fileManager)
            try validateReplacementVolumes(replacement, fileManager: fileManager)
            let plan = try prepareRollbackPlan(replacement, fileManager: fileManager)
            try cleanupInstalledIncomingArtifacts(
                plan.incoming,
                expectedDigests: replacement.incomingDigests,
                fileManager: fileManager
            )
            try cleanupReplacementDirectories(
                plan.replacementDirectories,
                root: plan.incoming.root,
                fileManager: fileManager
            )
            _ = try cleanupManagedArtifacts(
                plan.restoration?.entries.map(\.artifact) ?? [],
                fileManager: fileManager
            )
            if let restoration = plan.restoration {
                try restoreBackedUpArtifacts(
                    restoration,
                    fileManager: fileManager
                )
            }
            try synchronizeReplacementMutations(
                replacement,
                sourceRoot: plan.restoration?.sourceRoot.unresolved,
                sourceArtifacts: replacement.backedUpArtifacts,
                fileManager: fileManager
            )
        }

        private func preflightReplacementApply(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            try validateReplacementArtifactRoot(replacement, fileManager: fileManager)
            try validateReplacementVolumes(replacement, fileManager: fileManager)
            try validateTransactionArtifacts(replacement, fileManager: fileManager)
            guard try !replacementApplyHasStarted(replacement, fileManager: fileManager) else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "replacement apply already started at \(replacement.directory.path)"
                )
            }

            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            let volumeSupportsCaseSensitiveNames =
                try Self.destinationVolumeSupportsCaseSensitiveNames(
                    for: root,
                    fileManager: fileManager
                )
            let currentMutationPathKinds = try Self.mutationPathKinds(
                for: replacement.mutationArtifacts,
                root: root,
                fileManager: fileManager
            )
            for artifact in replacement.mutationArtifacts {
                guard
                    currentMutationPathKinds[artifact]
                        == replacement.mutationPathKinds[artifact]
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: Self.artifactURL(artifact, under: artifactRoot).path
                    )
                }
            }
            for artifact in replacement.backedUpArtifacts {
                guard
                    case .leaf(let url, .some(.regularFile)) = try Self.inspectArtifactPath(
                        artifact,
                        root: root,
                        fileManager: fileManager
                    ),
                    try Self.sha256(of: url) == replacement.backedUpDigests[artifact]
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: Self.artifactURL(artifact, under: artifactRoot).path
                    )
                }
            }

            for artifact in replacement.incomingArtifacts {
                switch try Self.inspectArtifactPath(
                    artifact,
                    root: root,
                    fileManager: fileManager
                ) {
                case .missingParent, .leaf(_, nil):
                    continue
                case .leaf(let url, .some(.regularFile)):
                    guard
                        let backedUpArtifact = replacement.backedUpArtifacts.first(where: {
                            Self.artifactPathsAreEquivalent(
                                $0,
                                artifact,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            )
                        }),
                        try Self.sha256(of: url)
                            == replacement.backedUpDigests[backedUpArtifact]
                    else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: url.path
                        )
                    }
                case .occupiedParent(_, .regularFile):
                    guard replacement.backedUpArtifacts.contains(where: {
                        Self.pathIsAncestor(
                            $0,
                            of: artifact,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: Self.artifactURL(artifact, under: artifactRoot).path
                        )
                    }
                case .leaf(_, .some(.directory)):
                    guard replacement.backedUpArtifacts.contains(where: {
                        Self.pathIsAncestor(
                            artifact,
                            of: $0,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: Self.artifactURL(artifact, under: artifactRoot).path
                        )
                    }
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: artifact,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: url.path
                    )
                case .leaf(let url, .some(.other)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: artifact,
                        expected: "regular file, directory, or missing",
                        actual: "special file at \(url.path)"
                    )
                }
            }
        }

        private func prepareRollbackPlan(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws -> RollbackPlan {
            let restoration = try prepareBackedUpArtifactRestoration(
                replacement,
                fileManager: fileManager
            )
            let incoming = try prepareIncomingRollback(
                replacement,
                fileManager: fileManager
            )
            let replacementDirectories = try validateBackedUpLiveArtifactsForRollback(
                replacement,
                installedIncomingArtifacts: incoming.installedArtifacts,
                fileManager: fileManager
            )
            return RollbackPlan(
                incoming: incoming,
                replacementDirectories: replacementDirectories,
                restoration: restoration
            )
        }

        private func prepareIncomingRollback(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws -> IncomingRollbackPlan {
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            let stagedRoot = try Self.artifactRootURLs(
                for: replacement.incomingRoot,
                fileManager: fileManager
            )
            try Self.validateStagedRoot(stagedRoot, fileManager: fileManager)
            let volumeSupportsCaseSensitiveNames =
                try Self.destinationVolumeSupportsCaseSensitiveNames(
                    for: root,
                    fileManager: fileManager
                )
            var installedArtifacts: [ArtifactPath] = []

            for artifact in Self.cleanupOperationOrder(replacement.incomingArtifacts) {
                let expectedDigest = try Self.requiredDigest(
                    for: artifact,
                    in: replacement.incomingDigests
                )
                switch try Self.inspectArtifactPath(
                    artifact,
                    root: stagedRoot,
                    fileManager: fileManager
                ) {
                case .leaf(let source, .some(.regularFile)):
                    guard try Self.sha256(of: source) == expectedDigest else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: source.path
                        )
                    }
                case .missingParent, .leaf(_, nil):
                    switch try Self.inspectArtifactPath(
                        artifact,
                        root: root,
                        fileManager: fileManager
                    ) {
                    case .missingParent, .leaf(_, nil):
                        break
                    case .leaf(let destination, .some(.regularFile)):
                        let actualDigest = try Self.sha256(of: destination)
                        let matchesBackedUpArtifact = replacement.backedUpDigests.contains(where: {
                            Self.artifactPathsAreEquivalent(
                                $0.key,
                                artifact,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            ) && $0.value == actualDigest
                        })
                        if matchesBackedUpArtifact {
                            break
                        }
                        if actualDigest == expectedDigest {
                            installedArtifacts.append(artifact)
                        } else {
                            throw ArtifactStoreError.artifactContentChanged(
                                artifactPath: artifact,
                                path: destination.path
                            )
                        }
                    case .leaf(_, .some(.directory)):
                        guard replacement.backedUpArtifacts.contains(where: {
                            Self.pathIsAncestor(
                                artifact,
                                of: $0,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            )
                        }) else {
                            throw ArtifactStoreError.artifactContentChanged(
                                artifactPath: artifact,
                                path: Self.artifactURL(artifact, under: artifactRoot).path
                            )
                        }
                    case .occupiedParent(_, .regularFile):
                        guard replacement.backedUpArtifacts.contains(where: {
                            Self.pathIsAncestor(
                                $0,
                                of: artifact,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            )
                        }) else {
                            throw ArtifactStoreError.artifactContentChanged(
                                artifactPath: artifact,
                                path: Self.artifactURL(artifact, under: artifactRoot).path
                            )
                        }
                    case .occupiedParent(let url, let kind):
                        throw ArtifactStoreError.cleanupParentTypeMismatch(
                            artifactPath: artifact,
                            parentPath: url.path,
                            actual: Self.artifactItemKindDescription(kind)
                        )
                    case .symbolicLinkParent(let url),
                        .leaf(let url, .some(.symbolicLink)):
                        throw ArtifactStoreError.symbolicLinkInArtifactPath(
                            artifactPath: artifact,
                            symbolicLinkPath: url.path
                        )
                    case .leaf(let url, .some(.other)):
                        throw ArtifactStoreError.commitDestinationTypeMismatch(
                            artifactPath: artifact,
                            expected: "regular file, directory, or missing",
                            actual: "special file at \(url.path)"
                        )
                    }
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(url.path)
                case .occupiedParent(let url, _), .leaf(let url, .some(.directory)),
                    .leaf(let url, .some(.other)):
                    throw ArtifactStoreError.stagedArtifactIsNotRegularFile(url.path)
                }
            }
            return IncomingRollbackPlan(
                root: root,
                stagedRoot: stagedRoot,
                installedArtifacts: installedArtifacts
            )
        }

        private func validateBackedUpLiveArtifactsForRollback(
            _ replacement: Replacement,
            installedIncomingArtifacts: [ArtifactPath],
            fileManager: FileManager
        ) throws -> [ArtifactPath] {
            let root = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            let volumeSupportsCaseSensitiveNames =
                try Self.destinationVolumeSupportsCaseSensitiveNames(
                    for: root,
                    fileManager: fileManager
                )
            var replacementDirectories = Set<ArtifactPath>()
            for artifact in replacement.backedUpArtifacts {
                switch try Self.inspectArtifactPath(
                    artifact,
                    root: root,
                    fileManager: fileManager
                ) {
                case .missingParent, .leaf(_, nil):
                    continue
                case .leaf(let url, .some(.regularFile)):
                    let actualDigest = try Self.sha256(of: url)
                    if actualDigest == replacement.backedUpDigests[artifact] {
                        continue
                    }
                    guard installedIncomingArtifacts.contains(where: {
                        Self.artifactPathsAreEquivalent(
                            artifact,
                            $0,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        ) && replacement.incomingDigests[$0] == actualDigest
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: url.path
                        )
                    }
                case .leaf(let directory, .some(.directory)):
                    guard replacement.incomingArtifacts.contains(where: {
                        Self.pathIsAncestor(
                            artifact,
                            of: $0,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: Self.artifactURL(artifact, under: artifactRoot).path
                        )
                    }
                    replacementDirectories.formUnion(
                        try validateReplacementDirectoryContents(
                            at: directory,
                            artifact: artifact,
                            incomingArtifacts: replacement.incomingArtifacts,
                            installedIncomingArtifacts: installedIncomingArtifacts,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames,
                            fileManager: fileManager
                        )
                    )
                case .occupiedParent(_, .regularFile):
                    guard installedIncomingArtifacts.contains(where: {
                        Self.pathIsAncestor(
                            $0,
                            of: artifact,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: Self.artifactURL(artifact, under: artifactRoot).path
                        )
                    }
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: artifact,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: url.path
                    )
                case .leaf(let url, .some(.other)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: artifact,
                        expected: "regular file, directory, or missing",
                        actual: "special file at \(url.path)"
                    )
                }
            }
            return replacementDirectories.sorted {
                let leftDepth = Self.pathDepth($0)
                let rightDepth = Self.pathDepth($1)
                return leftDepth == rightDepth
                    ? $0.rawValue < $1.rawValue
                    : leftDepth > rightDepth
            }
        }

        private func validateReplacementDirectoryContents(
            at directory: URL,
            artifact: ArtifactPath,
            incomingArtifacts: [ArtifactPath],
            installedIncomingArtifacts: [ArtifactPath],
            volumeSupportsCaseSensitiveNames: Bool,
            fileManager: FileManager
        ) throws -> Set<ArtifactPath> {
            var directories: Set<ArtifactPath> = [artifact]
            var pending: [(url: URL, artifact: ArtifactPath)] = [(directory, artifact)]
            while let current = pending.popLast() {
                for childURL in try fileManager.contentsOfDirectory(
                    at: current.url,
                    includingPropertiesForKeys: nil,
                    options: []
                ) {
                    let child = try ArtifactPath(
                        current.artifact.rawValue + "/" + childURL.lastPathComponent
                    )
                    guard let kind = try Self.artifactItemKind(
                        at: childURL,
                        fileManager: fileManager
                    ) else { continue }
                    switch kind {
                    case .directory:
                        guard incomingArtifacts.contains(where: {
                            Self.pathIsAncestor(
                                child,
                                of: $0,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            )
                        }) else {
                            throw ArtifactStoreError.artifactContentChanged(
                                artifactPath: child,
                                path: childURL.path
                            )
                        }
                        directories.insert(child)
                        pending.append((childURL, child))
                    case .regularFile:
                        guard installedIncomingArtifacts.contains(where: {
                            Self.artifactPathsAreEquivalent(
                                child,
                                $0,
                                volumeSupportsCaseSensitiveNames:
                                    volumeSupportsCaseSensitiveNames
                            )
                        }) else {
                            throw ArtifactStoreError.artifactContentChanged(
                                artifactPath: child,
                                path: childURL.path
                            )
                        }
                    case .symbolicLink:
                        throw ArtifactStoreError.symbolicLinkInArtifactPath(
                            artifactPath: child,
                            symbolicLinkPath: childURL.path
                        )
                    case .other:
                        throw ArtifactStoreError.commitDestinationTypeMismatch(
                            artifactPath: child,
                            expected: "generated replacement contents",
                            actual: "special file at \(childURL.path)"
                        )
                    }
                }
            }
            return directories
        }

        private func cleanupReplacementDirectories(
            _ directories: [ArtifactPath],
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws {
            for directory in directories {
                switch try Self.inspectArtifactPath(
                    directory,
                    root: root,
                    fileManager: fileManager
                ) {
                case .missingParent, .leaf(_, nil):
                    continue
                case .leaf(let url, .some(.directory)):
                    guard try fileManager.contentsOfDirectory(atPath: url.path).isEmpty else {
                        throw ArtifactStoreError.cleanupDirectoryNotEmpty(
                            artifactPath: directory,
                            directoryPath: url.path
                        )
                    }
                    try fileManager.removeItem(at: url)
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: directory,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: directory,
                        symbolicLinkPath: url.path
                    )
                case .leaf(let url, .some(let kind)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: directory,
                        expected: "empty directory or missing",
                        actual: "\(Self.artifactItemKindDescription(kind)) at \(url.path)"
                    )
                }
            }
        }

        private func cleanupInstalledIncomingArtifacts(
            _ plan: IncomingRollbackPlan,
            expectedDigests: [ArtifactPath: String],
            fileManager: FileManager
        ) throws {
            try Self.validateStagedRoot(plan.stagedRoot, fileManager: fileManager)
            let candidates = Self.cleanupCandidates(
                manifestArtifacts: plan.installedArtifacts
            )
            let candidateSet = Set(candidates)

            for artifact in candidates {
                guard
                    case .leaf(let url, .some(.regularFile)) = try Self.inspectArtifactPath(
                        artifact,
                        root: plan.root,
                        fileManager: fileManager
                    ),
                    try Self.sha256(of: url)
                        == Self.requiredDigest(for: artifact, in: expectedDigests)
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: Self.artifactURL(artifact, under: artifactRoot).path
                    )
                }
            }

            for artifact in Self.cleanupOperationOrder(candidates) {
                guard
                    case .leaf(let url, .some(.regularFile)) = try Self.inspectArtifactPath(
                        artifact,
                        root: plan.root,
                        fileManager: fileManager
                    ),
                    try Self.sha256(of: url)
                        == Self.requiredDigest(for: artifact, in: expectedDigests)
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: Self.artifactURL(artifact, under: artifactRoot).path
                    )
                }
                try fileManager.removeItem(at: url)
                _ = try Self.pruneEmptyParentDirectories(
                    afterDeleting: artifact,
                    root: plan.root,
                    cleanupCandidates: candidateSet,
                    fileManager: fileManager
                )
            }
        }

        private func prepareBackedUpArtifactRestoration(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws -> RestorationPlan? {
            guard !replacement.backedUpArtifacts.isEmpty else { return nil }
            let backupSourceRoot = try Self.artifactRootURLs(
                for: replacement.backupRoot,
                fileManager: fileManager
            )
            let sourceRoot = try Self.artifactRootURLs(
                for: replacement.restoreRoot,
                fileManager: fileManager
            )
            let destinationRoot = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            try Self.validateStagedRoot(backupSourceRoot, fileManager: fileManager)
            try Self.validateStagedRoot(sourceRoot, fileManager: fileManager)
            let artifacts = Self.cleanupCandidates(
                manifestArtifacts: replacement.backedUpArtifacts
            )
            try Self.validateDestinationCollisions(artifacts)
            let volumeSupportsCaseSensitiveNames =
                try Self.destinationVolumeSupportsCaseSensitiveNames(
                    for: destinationRoot,
                    fileManager: fileManager
                )
            var entries: [RestorationEntry] = []
            entries.reserveCapacity(artifacts.count)

            for artifact in artifacts {
                let backupInspection = try Self.inspectArtifactPath(
                    artifact,
                    root: backupSourceRoot,
                    fileManager: fileManager
                )
                let backupSource: URL
                switch backupInspection {
                case .leaf(let url, .some(.regularFile)):
                    backupSource = url
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(url.path)
                case .missingParent, .leaf(_, nil):
                    throw ArtifactStoreError.missingStagedArtifact(
                        Self.artifactURL(artifact, under: replacement.backupRoot).path
                    )
                case .occupiedParent(let url, _), .leaf(let url, .some(.directory)),
                    .leaf(let url, .some(.other)):
                    throw ArtifactStoreError.stagedArtifactIsNotRegularFile(url.path)
                }
                let expectedDigest = try Self.requiredDigest(
                    for: artifact,
                    in: replacement.backedUpDigests
                )
                guard try Self.sha256(of: backupSource) == expectedDigest else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: backupSource.path
                    )
                }

                let restoreSource: URL?
                switch try Self.inspectArtifactPath(
                    artifact,
                    root: sourceRoot,
                    fileManager: fileManager
                ) {
                case .leaf(let url, .some(.regularFile)):
                    guard try Self.sha256(of: url) == expectedDigest else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: url.path
                        )
                    }
                    restoreSource = url
                case .missingParent, .leaf(_, nil):
                    restoreSource = nil
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(url.path)
                case .occupiedParent(let url, _), .leaf(let url, .some(.directory)),
                    .leaf(let url, .some(.other)):
                    throw ArtifactStoreError.stagedArtifactIsNotRegularFile(url.path)
                }
                let destination = try Self.commitDestinationURL(
                    for: artifact,
                    root: destinationRoot,
                    fileManager: fileManager
                )
                let destinationAlreadyRestored: Bool
                switch try Self.inspectArtifactPath(
                    artifact,
                    root: destinationRoot,
                    fileManager: fileManager
                ) {
                case .leaf(let url, .some(.regularFile)):
                    destinationAlreadyRestored = try Self.sha256(of: url) == expectedDigest
                case .missingParent, .occupiedParent, .symbolicLinkParent, .leaf:
                    destinationAlreadyRestored = false
                }
                if restoreSource == nil, destinationAlreadyRestored {
                    continue
                }
                guard let restoreSource else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: destination.path
                    )
                }
                guard !Self.pathsOverlap(
                    restoreSource,
                    destination,
                    volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
                ) else {
                    throw ArtifactStoreError.commitSourceDestinationOverlap(
                        source: restoreSource.path,
                        destination: destination.path
                    )
                }
                entries.append(
                    RestorationEntry(
                        artifact: artifact,
                        source: restoreSource,
                        destination: destination,
                        digest: expectedDigest
                    )
                )
            }
            return RestorationPlan(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                entries: entries
            )
        }

        private func restoreBackedUpArtifacts(
            _ plan: RestorationPlan,
            fileManager: FileManager
        ) throws {
            try Self.validateStagedRoot(plan.sourceRoot, fileManager: fileManager)
            var preparedDestinationDirectories: Set<URL> = []
            for entry in plan.entries {
                guard
                    case .leaf(let source, .some(.regularFile)) = try Self.inspectArtifactPath(
                        entry.artifact,
                        root: plan.sourceRoot,
                        fileManager: fileManager
                    ),
                    try Self.sha256(of: source) == entry.digest
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: entry.artifact,
                        path: entry.source.path
                    )
                }
                switch try Self.inspectArtifactPath(
                    entry.artifact,
                    root: plan.destinationRoot,
                    fileManager: fileManager
                ) {
                case .missingParent, .leaf(_, nil):
                    break
                case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: entry.artifact,
                        symbolicLinkPath: url.path
                    )
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: entry.artifact,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .leaf(_, .some(let kind)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: entry.artifact,
                        expected: "missing destination",
                        actual: Self.artifactItemKindDescription(kind)
                    )
                }
            }

            for entry in plan.entries {
                try Self.validateStagedRoot(plan.sourceRoot, fileManager: fileManager)
                guard
                    case .leaf(let source, .some(.regularFile)) = try Self.inspectArtifactPath(
                        entry.artifact,
                        root: plan.sourceRoot,
                        fileManager: fileManager
                    ),
                    try Self.sha256(of: source) == entry.digest
                else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: entry.artifact,
                        path: entry.source.path
                    )
                }
                let destinationDirectory =
                    entry.destination.deletingLastPathComponent().standardizedFileURL
                if preparedDestinationDirectories.insert(destinationDirectory).inserted {
                    try ManagedFileSystem.ensureRealDirectory(destinationDirectory)
                }
                guard
                    case .leaf(_, nil) = try Self.inspectArtifactPath(
                        entry.artifact,
                        root: plan.destinationRoot,
                        fileManager: fileManager
                    )
                else {
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: entry.artifact,
                        expected: "missing destination",
                        actual: "changed destination"
                    )
                }
                try ManagedFileSystem.atomicRenameExclusively(
                    from: entry.source,
                    to: entry.destination
                )
            }
        }

        private static func validateStagedRoot(
            _ root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws {
            try validateStagedItem(
                at: root.unresolved,
                expectedKind: .directory,
                fileManager: fileManager
            )
            guard
                root.unresolved.resolvingSymlinksInPath().standardizedFileURL.path
                    == root.resolved.path
            else {
                throw ArtifactStoreError.stagingDirectoryChanged(root.unresolved.path)
            }
        }

        private func markReplacementApplyStarted(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            let markerURL = replacement.directory.appendingPathComponent(
                "apply.started",
                isDirectory: false
            )
            guard try Self.artifactItemKind(at: markerURL, fileManager: fileManager) == nil else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "replacement apply marker already exists at \(markerURL.path)"
                )
            }
            try Data("started\n".utf8).write(to: markerURL, options: .withoutOverwriting)
            try ManagedFileSystem.syncFile(markerURL)
            try ManagedFileSystem.syncDirectory(replacement.directory)
        }

        private func replacementApplyHasStarted(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws -> Bool {
            let markerURL = replacement.directory.appendingPathComponent(
                "apply.started",
                isDirectory: false
            )
            guard let kind = try Self.artifactItemKind(at: markerURL, fileManager: fileManager)
            else { return false }
            guard kind == .regularFile else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "replacement apply marker is not a regular file at \(markerURL.path)"
                )
            }
            return true
        }

        internal func finalizeReplacement(
            _ replacement: Replacement,
            fileManager: FileManager = .default
        ) throws {
            try removeReplacementTransaction(replacement, fileManager: fileManager)
        }

        private func removeReplacementTransaction(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            guard
                let kind = try Self.artifactItemKind(
                    at: replacement.directory,
                    fileManager: fileManager
                )
            else { return }
            guard kind == .directory else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "transaction is not a directory at \(replacement.directory.path)"
                )
            }
            let manifestURL = replacement.directory.appendingPathComponent(
                "manifest.json",
                isDirectory: false
            )
            if let manifestKind = try Self.artifactItemKind(
                at: manifestURL,
                fileManager: fileManager
            ) {
                guard manifestKind == .regularFile else {
                    throw ArtifactStoreError.invalidReplacementManifest(
                        "manifest is not a regular file at \(manifestURL.path)"
                    )
                }
                try fileManager.removeItem(at: manifestURL)
                try ManagedFileSystem.syncDirectory(replacement.directory)
            }
            try fileManager.removeItem(at: replacement.directory)
        }

        internal static func pendingReplacements(
            in replacementsRoot: URL,
            artifactRoot: URL,
            fileManager: FileManager = .default
        ) throws -> [Replacement] {
            guard let rootKind = try artifactItemKind(at: replacementsRoot, fileManager: fileManager)
            else { return [] }
            guard rootKind == .directory else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "replacement root is not a directory at \(replacementsRoot.path)"
                )
            }
            var replacements: [Replacement] = []
            for runDirectory in try fileManager.contentsOfDirectory(
                at: replacementsRoot,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted(by: { $0.path < $1.path }) {
                guard try artifactItemKind(at: runDirectory, fileManager: fileManager) == .directory
                else {
                    throw ArtifactStoreError.invalidReplacementManifest(
                        "replacement run entry is not a directory at \(runDirectory.path)"
                    )
                }
                for transactionDirectory in try fileManager.contentsOfDirectory(
                    at: runDirectory,
                    includingPropertiesForKeys: nil,
                    options: []
                ).sorted(by: { $0.path < $1.path }) {
                    guard
                        try artifactItemKind(at: transactionDirectory, fileManager: fileManager)
                            == .directory
                    else {
                        throw ArtifactStoreError.invalidReplacementManifest(
                            "replacement target entry is not a directory at \(transactionDirectory.path)"
                        )
                    }
                    let manifestURL = transactionDirectory.appendingPathComponent(
                        "manifest.json",
                        isDirectory: false
                    )
                    guard try artifactItemKind(at: manifestURL, fileManager: fileManager) != nil else {
                        continue
                    }
                    replacements.append(
                        try loadReplacement(
                            at: transactionDirectory,
                            artifactRoot: artifactRoot,
                            fileManager: fileManager
                        )
                    )
                }
            }
            return replacements
        }

        internal static func cleanupReplacementStaging(
            _ replacementsRoot: URL,
            fileManager: FileManager = .default
        ) throws {
            guard let kind = try artifactItemKind(at: replacementsRoot, fileManager: fileManager)
            else { return }
            guard kind == .directory else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "replacement root is not a directory at \(replacementsRoot.path)"
                )
            }
            try fileManager.removeItem(at: replacementsRoot)
        }

        private func applyPreparedIncoming(
            _ plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            try preflightCommit(plan, fileManager: fileManager)
            try validateIncomingDestinationsAreMissing(plan, fileManager: fileManager)
            for entry in plan.entries where entry.kind == .directory {
                let destination = try revalidate(entry, in: plan, fileManager: fileManager)
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            }
            for entry in plan.entries where entry.kind == .file {
                let destination = try revalidate(entry, in: plan, fileManager: fileManager)
                try ManagedFileSystem.atomicRenameExclusively(
                    from: entry.source,
                    to: destination
                )
            }
        }

        private func validateIncomingDestinationsAreMissing(
            _ plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            for entry in plan.entries where entry.kind == .file {
                let destination = try Self.commitDestinationURL(
                    for: entry.artifact,
                    root: plan.root,
                    fileManager: fileManager
                )
                guard
                    let kind = try Self.artifactItemKind(
                        at: destination,
                        fileManager: fileManager
                    )
                else { continue }
                if kind == .symbolicLink {
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: entry.artifact,
                        symbolicLinkPath: destination.path
                    )
                }
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: entry.artifact,
                    expected: "missing destination",
                    actual: Self.artifactItemKindDescription(kind)
                )
            }
        }

        private func prepareMutation(
            _ artifacts: [ArtifactPath],
            preferring preferredArtifacts: [ArtifactPath],
            from root: ArtifactRootURLs,
            to backupRoot: URL,
            volumeSupportsCaseSensitiveNames: Bool,
            fileManager: FileManager
        ) throws -> PreparedMutation {
            var backedUpArtifacts: [ArtifactPath] = []
            var pathKinds: [ArtifactPath: MutationPathKind] = [:]
            var sourceByPortablePath:
                [String: (artifact: ArtifactPath, canonicalSourcePath: String)] = [:]
            let preferredArtifacts = Set(preferredArtifacts)
            let candidates = Self.cleanupCandidates(manifestArtifacts: artifacts).sorted {
                let leftDepth = Self.pathDepth($0)
                let rightDepth = Self.pathDepth($1)
                if leftDepth == rightDepth {
                    let leftIsPreferred = preferredArtifacts.contains($0)
                    let rightIsPreferred = preferredArtifacts.contains($1)
                    if leftIsPreferred != rightIsPreferred {
                        return leftIsPreferred
                    }
                    return $0.rawValue < $1.rawValue
                }
                return leftDepth < rightDepth
            }
            for artifact in candidates {
                let inspection = try Self.inspectArtifactPath(
                    artifact,
                    root: root,
                    fileManager: fileManager
                )
                pathKinds[artifact] = try Self.mutationPathKind(
                    for: inspection,
                    artifact: artifact
                )
                switch inspection {
                case .missingParent, .leaf(_, nil):
                    continue
                case .occupiedParent(_, .regularFile):
                    guard backedUpArtifacts.contains(where: {
                        Self.pathIsAncestor(
                            $0,
                            of: artifact,
                            volumeSupportsCaseSensitiveNames:
                                volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.artifactContentChanged(
                            artifactPath: artifact,
                            path: Self.artifactURL(artifact, under: root.unresolved).path
                        )
                    }
                case .occupiedParent(let url, let kind):
                    throw ArtifactStoreError.cleanupParentTypeMismatch(
                        artifactPath: artifact,
                        parentPath: url.path,
                        actual: Self.artifactItemKindDescription(kind)
                    )
                case .symbolicLinkParent(let url):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: url.path
                    )
                case .leaf(let source, .some(.regularFile)):
                    let portablePath = Self.portableCollisionKey(for: artifact.rawValue)
                    let canonicalSourcePath =
                        source.resolvingSymlinksInPath().standardizedFileURL.path
                    if let existing = sourceByPortablePath[portablePath] {
                        guard existing.canonicalSourcePath == canonicalSourcePath else {
                            throw ArtifactStoreError.commitDestinationCollision(
                                first: existing.artifact,
                                second: artifact
                            )
                        }
                        continue
                    }
                    let destination = Self.artifactURL(artifact, under: backupRoot)
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: source, to: destination)
                    sourceByPortablePath[portablePath] = (artifact, canonicalSourcePath)
                    backedUpArtifacts.append(artifact)
                case .leaf(let source, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: source.path
                    )
                case .leaf(_, .some(.directory)):
                    guard candidates.contains(where: {
                        Self.pathIsAncestor(
                            artifact,
                            of: $0,
                            volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
                        )
                    }) else {
                        throw ArtifactStoreError.commitDestinationTypeMismatch(
                            artifactPath: artifact,
                            expected: "regular file",
                            actual: Self.artifactItemKindDescription(.directory)
                        )
                    }
                case .leaf(_, .some(.other)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: artifact,
                        expected: "regular file",
                        actual: "non-regular file"
                    )
                }
            }
            return PreparedMutation(
                backedUpArtifacts: backedUpArtifacts.sorted { $0.rawValue < $1.rawValue },
                pathKinds: pathKinds
            )
        }

        private static func mutationPathKind(
            for inspection: ArtifactPathInspection,
            artifact: ArtifactPath
        ) throws -> MutationPathKind {
            switch inspection {
            case .missingParent, .leaf(_, nil):
                return .missing
            case .occupiedParent(_, .regularFile):
                return .occupiedByRegularFile
            case .leaf(_, .some(.regularFile)):
                return .regularFile
            case .leaf(_, .some(.directory)):
                return .directory
            case .occupiedParent(let url, let kind):
                throw ArtifactStoreError.cleanupParentTypeMismatch(
                    artifactPath: artifact,
                    parentPath: url.path,
                    actual: artifactItemKindDescription(kind)
                )
            case .symbolicLinkParent(let url), .leaf(let url, .some(.symbolicLink)):
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: artifact,
                    symbolicLinkPath: url.path
                )
            case .leaf(let url, .some(.other)):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: artifact,
                    expected: "regular file, directory, or missing",
                    actual: "special file at \(url.path)"
                )
            }
        }

        private static func mutationPathKinds(
            for artifacts: [ArtifactPath],
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> [ArtifactPath: MutationPathKind] {
            var kinds: [ArtifactPath: MutationPathKind] = [:]
            kinds.reserveCapacity(artifacts.count)
            for artifact in artifacts {
                kinds[artifact] = try mutationPathKind(
                    for: inspectArtifactPath(
                        artifact,
                        root: root,
                        fileManager: fileManager
                    ),
                    artifact: artifact
                )
            }
            return kinds
        }

        private static func pathIsAncestor(
            _ ancestor: ArtifactPath,
            of descendant: ArtifactPath,
            volumeSupportsCaseSensitiveNames: Bool
        ) -> Bool {
            let ancestorKey = volumeSupportsCaseSensitiveNames
                ? ancestor.rawValue.precomposedStringWithCanonicalMapping
                : portableCollisionKey(for: ancestor.rawValue)
            let descendantKey = volumeSupportsCaseSensitiveNames
                ? descendant.rawValue.precomposedStringWithCanonicalMapping
                : portableCollisionKey(for: descendant.rawValue)
            return descendantKey.hasPrefix(ancestorKey + "/")
        }

        private func writeManifest(
            for replacement: Replacement,
            fileManager: FileManager
        ) throws {
            let manifestURL = replacement.directory.appendingPathComponent(
                "manifest.json",
                isDirectory: false
            )
            guard try Self.artifactItemKind(at: manifestURL, fileManager: fileManager) == nil else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "manifest already exists at \(manifestURL.path)"
                )
            }
            try persistManifest(
                replacementManifest(for: replacement),
                at: manifestURL,
                transactionDirectory: replacement.directory
            )
        }

        private func replacementManifest(
            for replacement: Replacement
        ) throws -> ReplacementManifest {
            return ReplacementManifest(
                version: Self.replacementManifestVersion,
                runID: replacement.runID.rawValue,
                targetID: replacement.targetID,
                artifactRoot: replacement.artifactRoot.rawValue,
                incomingArtifacts: replacement.incomingArtifacts.map(\.rawValue),
                mutationArtifacts: replacement.mutationArtifacts.map(\.rawValue),
                mutationPathKinds: Dictionary(uniqueKeysWithValues:
                    replacement.mutationPathKinds.map { ($0.key.rawValue, $0.value) }
                ),
                backedUpArtifacts: replacement.backedUpArtifacts.map(\.rawValue),
                incomingDigests: Dictionary(uniqueKeysWithValues:
                    replacement.incomingDigests.map { ($0.key.rawValue, $0.value) }
                ),
                backedUpDigests: Dictionary(uniqueKeysWithValues:
                    replacement.backedUpDigests.map { ($0.key.rawValue, $0.value) }
                ),
                artifactRootIdentity: replacement.artifactRootIdentity
            )
        }

        private func persistManifest(
            _ manifest: ReplacementManifest,
            at manifestURL: URL,
            transactionDirectory: URL
        ) throws {
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            try ManagedFileSystem.syncFile(manifestURL)
            try ManagedFileSystem.syncDirectory(transactionDirectory)
        }

        private static func loadReplacement(
            at directory: URL,
            artifactRoot: URL,
            fileManager: FileManager
        ) throws -> Replacement {
            let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
            guard try artifactItemKind(at: manifestURL, fileManager: fileManager) == .regularFile
            else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "manifest is not a regular file at \(manifestURL.path)"
                )
            }
            let manifestData: Data
            do {
                manifestData = try Data(contentsOf: manifestURL)
            } catch {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "could not read \(manifestURL.path): \(error)"
                )
            }
            let version: Int
            do {
                version = try JSONDecoder().decode(
                    ReplacementManifestVersion.self,
                    from: manifestData
                ).version
            } catch {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "could not decode \(manifestURL.path): \(error)"
                )
            }
            guard version == Self.replacementManifestVersion else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "unsupported version \(version) at \(manifestURL.path)"
                )
            }
            let manifest: ReplacementManifest
            do {
                manifest = try JSONDecoder().decode(
                    ReplacementManifest.self,
                    from: manifestData
                )
            } catch {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "could not decode \(manifestURL.path): \(error)"
                )
            }
            let runID = try PrivateHeaderGeneration.RunID(manifest.runID)
            guard directory.deletingLastPathComponent().lastPathComponent == runID.rawValue else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "run identifier does not match its directory at \(manifestURL.path)"
                )
            }
            guard !manifest.targetID.isEmpty else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "target identifier is empty at \(manifestURL.path)"
                )
            }
            let artifactRootPath = try ArtifactPath(manifest.artifactRoot)
            let incomingArtifacts = try manifest.incomingArtifacts.map { try ArtifactPath($0) }
            let mutationArtifacts = try manifest.mutationArtifacts.map { try ArtifactPath($0) }
            var mutationPathKinds: [ArtifactPath: MutationPathKind] = [:]
            mutationPathKinds.reserveCapacity(manifest.mutationPathKinds.count)
            for (rawPath, kind) in manifest.mutationPathKinds {
                let artifact = try ArtifactPath(rawPath)
                guard mutationPathKinds[artifact] == nil else {
                    throw ArtifactStoreError.invalidReplacementManifest(
                        "manifest contains duplicate mutation path kinds at \(manifestURL.path)"
                    )
                }
                mutationPathKinds[artifact] = kind
            }
            let backedUpArtifacts = try manifest.backedUpArtifacts.map {
                try ArtifactPath($0)
            }
            guard Set(incomingArtifacts).count == incomingArtifacts.count,
                Set(mutationArtifacts).count == mutationArtifacts.count,
                Set(backedUpArtifacts).count == backedUpArtifacts.count
            else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "manifest contains duplicate paths at \(manifestURL.path)"
                )
            }
            let incomingDigests = try decodeDigests(
                manifest.incomingDigests,
                expectedArtifacts: incomingArtifacts,
                manifestURL: manifestURL
            )
            let backedUpDigests = try decodeDigests(
                manifest.backedUpDigests,
                expectedArtifacts: backedUpArtifacts,
                manifestURL: manifestURL
            )
            let mutationSet = Set(mutationArtifacts)
            guard incomingArtifacts.allSatisfy(mutationSet.contains),
                backedUpArtifacts.allSatisfy(mutationSet.contains),
                Set(mutationPathKinds.keys) == mutationSet
            else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "manifest paths do not form one mutation set at \(manifestURL.path)"
                )
            }
            let incomingRoot = directory.appendingPathComponent("incoming", isDirectory: true)
            let backupRoot = directory.appendingPathComponent("backup", isDirectory: true)
            let restoreRoot = directory.appendingPathComponent("restore", isDirectory: true)
            return Replacement(
                directory: directory,
                incomingRoot: incomingRoot,
                backupRoot: backupRoot,
                restoreRoot: restoreRoot,
                runID: runID,
                targetID: manifest.targetID,
                artifactRoot: artifactRootPath,
                incomingArtifacts: incomingArtifacts,
                mutationArtifacts: mutationArtifacts,
                mutationPathKinds: mutationPathKinds,
                backedUpArtifacts: backedUpArtifacts,
                incomingDigests: incomingDigests,
                backedUpDigests: backedUpDigests,
                artifactRootIdentity: manifest.artifactRootIdentity
            )
        }

        private func validateReplacementArtifactRoot(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            try Self.validateDirectoryIdentity(
                replacement.artifactRootIdentity,
                at: artifactRoot,
                fileManager: fileManager
            )
        }

        private func validateTransactionArtifacts(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            try Self.validateArtifactDigests(
                replacement.incomingDigests,
                for: replacement.incomingArtifacts,
                under: replacement.incomingRoot,
                fileManager: fileManager
            )
            try Self.validateArtifactDigests(
                replacement.backedUpDigests,
                for: replacement.backedUpArtifacts,
                under: replacement.backupRoot,
                fileManager: fileManager
            )
            try Self.validateArtifactDigests(
                replacement.backedUpDigests,
                for: replacement.backedUpArtifacts,
                under: replacement.restoreRoot,
                fileManager: fileManager
            )
        }

        private static func artifactDigests(
            for artifacts: [ArtifactPath],
            under rootURL: URL,
            fileManager: FileManager
        ) throws -> [ArtifactPath: String] {
            let root = try artifactRootURLs(for: rootURL, fileManager: fileManager)
            try validateStagedRoot(root, fileManager: fileManager)
            var digests: [ArtifactPath: String] = [:]
            digests.reserveCapacity(artifacts.count)
            for artifact in artifacts {
                guard
                    case .leaf(let url, .some(.regularFile)) = try inspectArtifactPath(
                        artifact,
                        root: root,
                        fileManager: fileManager
                    )
                else {
                    throw ArtifactStoreError.missingStagedArtifact(
                        artifactURL(artifact, under: rootURL).path
                    )
                }
                digests[artifact] = try sha256(of: url)
            }
            return digests
        }

        private static func copyArtifacts(
            _ artifacts: [ArtifactPath],
            from sourceRoot: URL,
            to destinationRoot: URL,
            expectedDigests: [ArtifactPath: String],
            fileManager: FileManager
        ) throws {
            var preparedDestinationDirectories: Set<URL> = []
            for artifact in artifacts {
                let source = artifactURL(artifact, under: sourceRoot)
                let destination = artifactURL(artifact, under: destinationRoot)
                let expectedDigest = try requiredDigest(for: artifact, in: expectedDigests)
                guard try sha256(of: source) == expectedDigest else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: source.path
                    )
                }
                let destinationDirectory =
                    destination.deletingLastPathComponent().standardizedFileURL
                if preparedDestinationDirectories.insert(destinationDirectory).inserted {
                    try ManagedFileSystem.ensureRealDirectory(destinationDirectory)
                }
                try fileManager.copyItem(at: source, to: destination)
                guard try sha256(of: destination) == expectedDigest else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: destination.path
                    )
                }
            }
        }

        private static func validateArtifactDigests(
            _ expectedDigests: [ArtifactPath: String],
            for artifacts: [ArtifactPath],
            under rootURL: URL,
            fileManager: FileManager
        ) throws {
            let actualDigests = try artifactDigests(
                for: artifacts,
                under: rootURL,
                fileManager: fileManager
            )
            for artifact in artifacts {
                guard actualDigests[artifact] == expectedDigests[artifact] else {
                    throw ArtifactStoreError.artifactContentChanged(
                        artifactPath: artifact,
                        path: artifactURL(artifact, under: rootURL).path
                    )
                }
            }
        }

        private static func requiredDigest(
            for artifact: ArtifactPath,
            in digests: [ArtifactPath: String]
        ) throws -> String {
            guard let digest = digests[artifact] else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "missing digest for \(artifact.rawValue)"
                )
            }
            return digest
        }

        private static func decodeDigests(
            _ rawDigests: [String: String],
            expectedArtifacts: [ArtifactPath],
            manifestURL: URL
        ) throws -> [ArtifactPath: String] {
            var digests: [ArtifactPath: String] = [:]
            digests.reserveCapacity(rawDigests.count)
            for (rawPath, digest) in rawDigests {
                let artifact = try ArtifactPath(rawPath)
                guard digests[artifact] == nil, isValidSHA256(digest) else {
                    throw ArtifactStoreError.invalidReplacementManifest(
                        "invalid digest entry for \(rawPath) at \(manifestURL.path)"
                    )
                }
                digests[artifact] = digest
            }
            guard Set(digests.keys) == Set(expectedArtifacts) else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "digest paths do not match artifact paths at \(manifestURL.path)"
                )
            }
            return digests
        }

        private static func sha256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { handle.closeFile() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        private static func isValidSHA256(_ digest: String) -> Bool {
            digest.utf8.count == 64 && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }

        private static func directoryIdentity(
            at url: URL,
            fileManager: FileManager
        ) throws -> FileSystemIdentity {
            guard try artifactItemKind(at: url, fileManager: fileManager) == .directory else {
                throw ArtifactStoreError.artifactRootTypeMismatch(
                    path: url.path,
                    actual: "missing or non-directory"
                )
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "filesystem identity is unavailable at \(url.path)"
                )
            }
            return FileSystemIdentity(device: device, inode: inode)
        }

        private static func validateDirectoryIdentity(
            _ expected: FileSystemIdentity,
            at url: URL,
            fileManager: FileManager
        ) throws {
            let actual = try directoryIdentity(at: url, fileManager: fileManager)
            guard actual == expected else {
                throw ArtifactStoreError.artifactRootChanged(
                    expected: expected.description,
                    actual: actual.description
                )
            }
        }

        private func validateReplacementVolumes(
            _ replacement: Replacement,
            fileManager: FileManager
        ) throws {
            try Self.validateReplacementVolumes(
                liveRoot: artifactRoot,
                liveRootIdentity: replacement.artifactRootIdentity,
                transactionRoots: [replacement.incomingRoot, replacement.restoreRoot],
                fileManager: fileManager
            )
        }

        private static func validateReplacementVolumes(
            liveRoot: URL,
            liveRootIdentity: FileSystemIdentity,
            transactionRoots: [URL],
            fileManager: FileManager
        ) throws {
            for transactionRoot in transactionRoots {
                let transactionIdentity = try directoryIdentity(
                    at: transactionRoot,
                    fileManager: fileManager
                )
                guard transactionIdentity.device == liveRootIdentity.device else {
                    throw ArtifactStoreError.replacementVolumeMismatch(
                        liveRoot: liveRoot.path,
                        transactionRoot: transactionRoot.path
                    )
                }
            }
        }

        private static func validateExclusiveRenameSupport(
            in transactionDirectory: URL,
            fileManager: FileManager,
            exclusiveRename: (URL, URL) throws -> Void
        ) throws {
            let probeID = UUID().uuidString.lowercased()
            let source = transactionDirectory.appendingPathComponent(
                ".rename-excl-source-\(probeID)",
                isDirectory: false
            )
            let destination = transactionDirectory.appendingPathComponent(
                ".rename-excl-destination-\(probeID)",
                isDirectory: false
            )
            try Data("probe\n".utf8).write(to: source, options: .withoutOverwriting)
            try exclusiveRename(source, destination)
            try fileManager.removeItem(at: destination)
        }

        private static func artifactPathsAreEquivalent(
            _ first: ArtifactPath,
            _ second: ArtifactPath,
            volumeSupportsCaseSensitiveNames: Bool
        ) -> Bool {
            artifactPathIdentityKey(
                for: first,
                volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
            ) == artifactPathIdentityKey(
                for: second,
                volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
            )
        }

        private static func artifactPathIdentityKey(
            for artifact: ArtifactPath,
            volumeSupportsCaseSensitiveNames: Bool
        ) -> String {
            let normalized = artifact.rawValue.precomposedStringWithCanonicalMapping
            guard !volumeSupportsCaseSensitiveNames else { return normalized }
            return portableCollisionKey(for: normalized)
        }

        private func synchronizeReplacementMutations(
            _ replacement: Replacement,
            sourceRoot: URL?,
            sourceArtifacts: [ArtifactPath],
            fileManager: FileManager
        ) throws {
            var directories = Self.mutationDirectories(
                for: replacement.mutationArtifacts,
                under: artifactRoot
            )
            if let sourceRoot {
                directories.formUnion(
                    Self.mutationDirectories(
                        for: sourceArtifacts,
                        under: sourceRoot
                    )
                )
            }
            try Self.syncExistingMutationDirectories(
                directories,
                fileManager: fileManager
            )
        }

        private static func mutationDirectories(
            for artifacts: [ArtifactPath],
            under root: URL
        ) -> Set<URL> {
            let root = root.standardizedFileURL
            var directories: Set<URL> = [root]
            for artifact in artifacts {
                var directory = root
                for component in artifact.rawValue.split(separator: "/").dropLast() {
                    directory.appendPathComponent(String(component), isDirectory: true)
                    directories.insert(directory.standardizedFileURL)
                }
            }
            return directories
        }

        private static func syncExistingMutationDirectories(
            _ directories: Set<URL>,
            fileManager: FileManager
        ) throws {
            for directory in directories.sorted(by: {
                let leftDepth = $0.standardizedFileURL.pathComponents.count
                let rightDepth = $1.standardizedFileURL.pathComponents.count
                return leftDepth == rightDepth ? $0.path < $1.path : leftDepth > rightDepth
            }) {
                switch try artifactItemKind(at: directory, fileManager: fileManager) {
                case nil, .some(.regularFile):
                    continue
                case .some(.directory):
                    try ManagedFileSystem.syncDirectory(directory)
                case .some(.symbolicLink):
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(directory.path)
                case .some(.other):
                    throw ArtifactStoreError.stagedArtifactIsNotDirectory(directory.path)
                }
            }
        }

        private static func syncTree(
            at root: URL,
            fileManager: FileManager
        ) throws {
            guard try artifactItemKind(at: root, fileManager: fileManager) == .directory else {
                throw ArtifactStoreError.stagedArtifactIsNotDirectory(root.path)
            }
            for child in try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                switch try artifactItemKind(at: child, fileManager: fileManager) {
                case .some(.directory):
                    try syncTree(at: child, fileManager: fileManager)
                case .some(.regularFile):
                    try ManagedFileSystem.syncFile(child)
                case .some(.symbolicLink):
                    throw ArtifactStoreError.symbolicLinkInStagingDirectory(child.path)
                case .some(.other):
                    throw ArtifactStoreError.stagedArtifactIsNotRegularFile(child.path)
                case nil:
                    throw ArtifactStoreError.missingStagedArtifact(child.path)
                }
            }
            try ManagedFileSystem.syncDirectory(root)
        }

        private static func nearestExistingRealDirectory(
            startingAt url: URL,
            fileManager: FileManager
        ) throws -> URL {
            var candidate = url.standardizedFileURL
            while true {
                if let kind = try artifactItemKind(at: candidate, fileManager: fileManager) {
                    guard kind == .directory else {
                        throw ArtifactStoreError.artifactRootTypeMismatch(
                            path: candidate.path,
                            actual: artifactItemKindDescription(kind)
                        )
                    }
                    return candidate
                }
                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                guard parent.path != candidate.path else {
                    throw ArtifactStoreError.artifactRootTypeMismatch(
                        path: candidate.path,
                        actual: "missing"
                    )
                }
                candidate = parent
            }
        }

        private static func syncDirectoryChain(
            from directory: URL,
            through ancestor: URL,
            fileManager: FileManager
        ) throws {
            let ancestor = ancestor.standardizedFileURL
            var current = directory.standardizedFileURL
            guard isSameOrDescendant(current, of: ancestor) else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "directory \(current.path) is outside durable ancestor \(ancestor.path)"
                )
            }
            while true {
                guard try artifactItemKind(at: current, fileManager: fileManager) == .directory else {
                    throw ArtifactStoreError.stagedArtifactIsNotDirectory(current.path)
                }
                try ManagedFileSystem.syncDirectory(current)
                if current.path == ancestor.path {
                    return
                }
                current = current.deletingLastPathComponent().standardizedFileURL
            }
        }

        private static func artifactURL(_ artifact: ArtifactPath, under root: URL) -> URL {
            artifact.rawValue.split(separator: "/").reduce(into: root) { url, component in
                url.appendPathComponent(String(component), isDirectory: false)
            }
        }

        private func write(
            _ plan: CommitPlan,
            preservingSources: Bool,
            fileManager: FileManager
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
                if preservingSources {
                    try fileManager.copyItem(at: entry.source, to: destination)
                } else {
                    try fileManager.moveItem(at: entry.source, to: destination)
                }
            }
        }

        @discardableResult
        public static func cleanupManagedArtifacts(
            in artifactRoot: URL,
            artifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> ArtifactCleanupResult {
            let root = try artifactRootURLs(for: artifactRoot, fileManager: fileManager)
            let candidates = cleanupCandidates(manifestArtifacts: artifacts)
            let candidateSet = Set(candidates)
            let artifactInspections = try cleanupArtifactInspections(
                for: candidates,
                root: root,
                fileManager: fileManager
            )
            var deletedArtifacts: [ArtifactPath] = []
            var missingArtifacts: [ArtifactPath] = []
            var prunedDirectories: [ArtifactPath] = []
            var prunedDirectorySet = Set<ArtifactPath>()
            var mutatedParentDirectories: [URL] = []

            do {
                for artifact in cleanupOperationOrder(candidates) {
                    guard case .leaf = artifactInspections[artifact]! else {
                        missingArtifacts.append(artifact)
                        mutatedParentDirectories.append(
                            Self.artifactURL(artifact, under: root.unresolved)
                                .deletingLastPathComponent()
                                .standardizedFileURL
                        )
                        continue
                    }
                    let inspection = try preflightCleanupArtifact(
                        for: artifact,
                        root: root,
                        fileManager: fileManager
                    )
                    guard case .leaf(let artifactURL, .some(_)) = inspection else {
                        missingArtifacts.append(artifact)
                        mutatedParentDirectories.append(
                            Self.artifactURL(artifact, under: root.unresolved)
                                .deletingLastPathComponent()
                                .standardizedFileURL
                        )
                        continue
                    }

                    try fileManager.removeItem(at: artifactURL)
                    deletedArtifacts.append(artifact)
                    mutatedParentDirectories.append(
                        artifactURL.deletingLastPathComponent().standardizedFileURL
                    )

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
            } catch {
                let primary = error
                do {
                    try synchronizeCleanupDirectories(
                        mutatedParentDirectories,
                        root: root,
                        fileManager: fileManager
                    )
                } catch {
                    throw ArtifactStoreError.cleanupSynchronizationFailed(
                        primary: String(describing: primary),
                        synchronization: String(describing: error)
                    )
                }
                throw primary
            }
            try synchronizeCleanupDirectories(
                mutatedParentDirectories,
                root: root,
                fileManager: fileManager
            )

            return ArtifactCleanupResult(
                deletedArtifacts: cleanupCandidates(manifestArtifacts: deletedArtifacts),
                missingArtifacts: cleanupCandidates(manifestArtifacts: missingArtifacts),
                prunedDirectories: cleanupCandidates(manifestArtifacts: prunedDirectories)
            )
        }

        private static func synchronizeCleanupDirectories(
            _ directories: [URL],
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws {
            var survivingDirectories: Set<URL> = []
            for directory in directories {
                var current = directory
                while true {
                    switch try artifactItemKind(at: current, fileManager: fileManager) {
                    case .directory:
                        survivingDirectories.insert(current)
                        break
                    case nil:
                        guard current.path != root.unresolved.path else {
                            throw ArtifactStoreError.artifactRootTypeMismatch(
                                path: root.unresolved.path,
                                actual: "missing"
                            )
                        }
                        current = current.deletingLastPathComponent().standardizedFileURL
                        continue
                    case .some(let kind):
                        throw ArtifactStoreError.artifactRootTypeMismatch(
                            path: current.path,
                            actual: artifactItemKindDescription(kind)
                        )
                    }
                    break
                }
            }
            for directory in survivingDirectories.sorted(by: { $0.path < $1.path }) {
                try ManagedFileSystem.syncDirectory(directory)
            }
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
            case regularFile
            case symbolicLink
            case other
        }

        private enum ArtifactPathInspection {
            case missingParent
            case occupiedParent(URL, ArtifactItemKind)
            case symbolicLinkParent(URL)
            case leaf(URL, ArtifactItemKind?)
        }

        private enum ExpectedStagedItemKind {
            case directory
            case regularFile
        }

        private static func artifactRootURLs(
            for artifactRoot: URL,
            fileManager: FileManager
        ) throws -> ArtifactRootURLs {
            guard artifactRoot.isFileURL else {
                throw ArtifactStoreError.nonFileArtifactRoot(artifactRoot.absoluteString)
            }

            let unresolved = artifactRoot.standardizedFileURL
            if let kind = try artifactItemKind(at: unresolved, fileManager: fileManager),
                kind != .directory
            {
                throw ArtifactStoreError.artifactRootTypeMismatch(
                    path: unresolved.path,
                    actual: artifactItemKindDescription(kind)
                )
            }
            return ArtifactRootURLs(
                unresolved: unresolved,
                resolved: unresolved.resolvingSymlinksInPath().standardizedFileURL
            )
        }

        private static func destinationVolumeSupportsCaseSensitiveNames(
            for root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> Bool {
            var candidate = root.resolved
            while true {
                let kind: ArtifactItemKind?
                do {
                    kind = try artifactItemKind(at: candidate, fileManager: fileManager)
                } catch {
                    throw ArtifactStoreError.destinationVolumeCaseSensitivityUnavailable(
                        root.resolved.path
                    )
                }

                if kind != nil {
                    let values: URLResourceValues
                    do {
                        values = try candidate.resourceValues(
                            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
                        )
                    } catch {
                        throw ArtifactStoreError.destinationVolumeCaseSensitivityUnavailable(
                            root.resolved.path
                        )
                    }
                    guard let supportsCaseSensitiveNames = values.volumeSupportsCaseSensitiveNames
                    else {
                        throw ArtifactStoreError.destinationVolumeCaseSensitivityUnavailable(
                            root.resolved.path
                        )
                    }
                    return supportsCaseSensitiveNames
                }

                let parent = candidate.deletingLastPathComponent().standardizedFileURL
                guard parent.path != candidate.path else {
                    throw ArtifactStoreError.destinationVolumeCaseSensitivityUnavailable(
                        root.resolved.path
                    )
                }
                candidate = parent
            }
        }

        private static func cleanupArtifactInspections(
            for artifacts: [ArtifactPath],
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> [ArtifactPath: ArtifactPathInspection] {
            var inspections: [ArtifactPath: ArtifactPathInspection] = [:]
            for artifact in artifacts {
                inspections[artifact] = try preflightCleanupArtifact(
                    for: artifact,
                    root: root,
                    fileManager: fileManager
                )
            }
            return inspections
        }

        private static func preflightCleanupArtifact(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> ArtifactPathInspection {
            let inspection = try cleanupArtifactInspection(
                for: artifact,
                root: root,
                fileManager: fileManager
            )
            if case .leaf(let url, .some(.directory)) = inspection {
                let contents = try fileManager.contentsOfDirectory(atPath: url.path)
                if !contents.isEmpty {
                    throw ArtifactStoreError.cleanupDirectoryNotEmpty(
                        artifactPath: artifact,
                        directoryPath: url.path
                    )
                }
            }
            return inspection
        }

        private static func cleanupArtifactInspection(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> ArtifactPathInspection {
            let inspection = try inspectArtifactPath(
                artifact,
                root: root,
                fileManager: fileManager
            )
            if case .symbolicLinkParent(let url) = inspection {
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: artifact,
                    symbolicLinkPath: url.path
                )
            }
            if case .occupiedParent(let url, let kind) = inspection {
                throw ArtifactStoreError.cleanupParentTypeMismatch(
                    artifactPath: artifact,
                    parentPath: url.path,
                    actual: artifactItemKindDescription(kind)
                )
            }
            return inspection
        }

        private static func inspectArtifactPath(
            _ artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> ArtifactPathInspection {
            let components = artifact.rawValue.split(
                separator: "/",
                omittingEmptySubsequences: false
            )
            var url = root.unresolved
            for (index, component) in components.enumerated() {
                url.appendPathComponent(String(component))
                let kind = try artifactItemKind(at: url, fileManager: fileManager)
                if index == components.count - 1 {
                    return .leaf(url, kind)
                }
                guard let kind else {
                    return .missingParent
                }
                if kind == .symbolicLink {
                    return .symbolicLinkParent(url)
                }
                guard kind == .directory else {
                    return .occupiedParent(url, kind)
                }
            }

            preconditionFailure("ArtifactPath validation guarantees at least one component")
        }

        private static func artifactItemKindDescription(_ kind: ArtifactItemKind) -> String {
            switch kind {
            case .directory:
                "directory"
            case .regularFile:
                "regular file"
            case .symbolicLink:
                "symbolic link"
            case .other:
                "special file"
            }
        }

        private static func commitEntries(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            artifacts: [ArtifactPath],
            fileManager: FileManager
        ) throws -> [CommitEntry] {
            try validateStagingBoundary(
                stagingDirectory: stagingDirectory,
                stagedSourceDirectory: stagedSourceDirectory,
                fileManager: fileManager
            )
            let sourceDirectory = stagedSourceDirectory.standardizedFileURL

            let rootComponents = artifactRoot.rawValue.split(separator: "/").map(String.init)
            var entriesByArtifact: [ArtifactPath: CommitEntry] = [
                artifactRoot: CommitEntry(
                    source: sourceDirectory,
                    artifact: artifactRoot,
                    kind: .directory
                )
            ]

            for artifact in artifacts {
                let components = artifact.rawValue.split(separator: "/").map(String.init)
                guard components.count > rootComponents.count,
                    components.prefix(rootComponents.count).elementsEqual(rootComponents)
                else {
                    throw ArtifactStoreError.artifactPathOutsideCommitRoot(
                        artifactPath: artifact,
                        artifactRoot: artifactRoot
                    )
                }

                let relativeComponents = Array(components.dropFirst(rootComponents.count))
                var source = sourceDirectory
                for (index, component) in relativeComponents.enumerated() {
                    source.appendPathComponent(component)
                    let isLeaf = index == relativeComponents.count - 1
                    try validateStagedItem(
                        at: source,
                        expectedKind: isLeaf ? .regularFile : .directory,
                        fileManager: fileManager
                    )

                    let entryArtifact = try ArtifactPath(
                        (rootComponents + relativeComponents.prefix(index + 1)).joined(
                            separator: "/")
                    )
                    entriesByArtifact[entryArtifact] = CommitEntry(
                        source: source,
                        artifact: entryArtifact,
                        kind: isLeaf ? .file : .directory
                    )
                }
            }

            let entries = entriesByArtifact.values.sorted {
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
            try validateDestinationCollisions(entries.map(\.artifact))
            return entries
        }

        private static func validateStagedItem(
            at url: URL,
            expectedKind: ExpectedStagedItemKind,
            fileManager: FileManager
        ) throws {
            guard let kind = try artifactItemKind(at: url, fileManager: fileManager) else {
                throw ArtifactStoreError.missingStagedArtifact(url.path)
            }
            guard kind != .symbolicLink else {
                throw ArtifactStoreError.symbolicLinkInStagingDirectory(url.path)
            }
            let hasExpectedKind =
                switch expectedKind {
                case .directory:
                    kind == .directory
                case .regularFile:
                    kind == .regularFile
                }
            guard hasExpectedKind else {
                switch expectedKind {
                case .directory:
                    throw ArtifactStoreError.stagedArtifactIsNotDirectory(url.path)
                case .regularFile:
                    throw ArtifactStoreError.stagedArtifactIsNotRegularFile(url.path)
                }
            }
        }

        private static func validateStagingBoundary(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            fileManager: FileManager
        ) throws {
            guard stagingDirectory.isFileURL else {
                throw ArtifactStoreError.nonFileStagingDirectory(
                    stagingDirectory.absoluteString
                )
            }
            guard stagedSourceDirectory.isFileURL else {
                throw ArtifactStoreError.nonFileStagingDirectory(
                    stagedSourceDirectory.absoluteString
                )
            }

            let stagingDirectory = stagingDirectory.standardizedFileURL
            let stagedSourceDirectory = stagedSourceDirectory.standardizedFileURL
            let stagingComponents = stagingDirectory.pathComponents
            let sourceComponents = stagedSourceDirectory.pathComponents
            guard sourceComponents.count >= stagingComponents.count,
                sourceComponents.prefix(stagingComponents.count).elementsEqual(stagingComponents)
            else {
                throw ArtifactStoreError.stagedSourceOutsideStagingDirectory(
                    stagedSource: stagedSourceDirectory.path,
                    stagingDirectory: stagingDirectory.path
                )
            }

            var current = stagingDirectory
            try validateStagedItem(
                at: current,
                expectedKind: .directory,
                fileManager: fileManager
            )
            for component in sourceComponents.dropFirst(stagingComponents.count) {
                current.appendPathComponent(component, isDirectory: true)
                try validateStagedItem(
                    at: current,
                    expectedKind: .directory,
                    fileManager: fileManager
                )
            }
        }

        private static func validateDestinationCollisions(
            _ artifacts: [ArtifactPath]
        ) throws {
            var artifactByCollisionKey: [String: ArtifactPath] = [:]
            for artifact in artifacts {
                let key = portableCollisionKey(for: artifact.rawValue)
                if let existing = artifactByCollisionKey[key] {
                    throw ArtifactStoreError.commitDestinationCollision(
                        first: existing,
                        second: artifact
                    )
                }
                artifactByCollisionKey[key] = artifact
            }
        }

        private static func portableCollisionKey(for path: String) -> String {
            // Do not derive this from the current volume. Persisted state and artifacts must
            // remain portable across volumes, and the ObjC header resolver disambiguates
            // case-only names.
            path
                .precomposedStringWithCanonicalMapping
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .precomposedStringWithCanonicalMapping
        }

        private static func commitDestinationURL(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs,
            fileManager: FileManager
        ) throws -> URL {
            var url = root.unresolved
            var resolvedURL = root.resolved
            for component in artifact.rawValue.split(
                separator: "/", omittingEmptySubsequences: false)
            {
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
            try preflightCommitInputs(plan, fileManager: fileManager)

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

        private func preflightCommitInputs(
            _ plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            try validateArtifactRoot(of: plan, fileManager: fileManager)
            try validateDestinationVolumeSemantics(of: plan, fileManager: fileManager)
            try validateStagingBoundary(of: plan, fileManager: fileManager)
            let currentEntries = try Self.commitEntries(
                stagingDirectory: plan.stagingDirectory,
                stagedSourceDirectory: plan.stagedSourceDirectory,
                artifactRoot: plan.artifactRoot,
                artifacts: plan.artifacts,
                fileManager: fileManager
            )
            guard currentEntries == plan.entries else {
                throw ArtifactStoreError.stagingDirectoryChanged(
                    plan.stagedSourceDirectory.path
                )
            }
            try Self.validateSourceDestinationDisjoint(plan)
        }

        private func revalidate(
            _ entry: CommitEntry,
            in plan: CommitPlan,
            fileManager: FileManager
        ) throws -> URL {
            try validateArtifactRoot(of: plan, fileManager: fileManager)
            try validateDestinationVolumeSemantics(of: plan, fileManager: fileManager)
            try validateStagingBoundary(of: plan, fileManager: fileManager)
            guard
                let sourceKind = try Self.artifactItemKind(
                    at: entry.source,
                    fileManager: fileManager
                )
            else {
                throw ArtifactStoreError.missingStagedArtifact(entry.source.path)
            }
            guard sourceKind != .symbolicLink else {
                throw ArtifactStoreError.symbolicLinkInStagingDirectory(entry.source.path)
            }
            let expectedSourceKind: ArtifactItemKind =
                entry.kind == .directory ? .directory : .regularFile
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

        private func validateStagingBoundary(
            of plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            try Self.validateStagingBoundary(
                stagingDirectory: plan.stagingDirectory,
                stagedSourceDirectory: plan.stagedSourceDirectory,
                fileManager: fileManager
            )
            let resolvedStagingDirectory = plan.stagingDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let resolvedStagedSourceDirectory = plan.stagedSourceDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard resolvedStagingDirectory.path == plan.resolvedStagingDirectory.path,
                resolvedStagedSourceDirectory.path == plan.resolvedStagedSourceDirectory.path
            else {
                throw ArtifactStoreError.stagingDirectoryChanged(
                    plan.stagingDirectory.path
                )
            }
        }

        private static func validateSourceDestinationDisjoint(
            _ plan: CommitPlan
        ) throws {
            let sources = [
                plan.resolvedStagingDirectory,
                plan.resolvedStagedSourceDirectory,
            ]
            for entry in plan.entries {
                let destination = resolvedArtifactURL(
                    for: entry.artifact,
                    root: plan.root
                )
                for source in sources
                where pathsOverlap(
                    source,
                    destination,
                    volumeSupportsCaseSensitiveNames: plan
                        .destinationVolumeSupportsCaseSensitiveNames
                ) {
                    throw ArtifactStoreError.commitSourceDestinationOverlap(
                        source: source.path,
                        destination: destination.path
                    )
                }
            }
        }

        private static func resolvedArtifactURL(
            for artifact: ArtifactPath,
            root: ArtifactRootURLs
        ) -> URL {
            var url = root.resolved
            for component in artifact.rawValue.split(
                separator: "/", omittingEmptySubsequences: false)
            {
                url.appendPathComponent(String(component))
            }
            return url.standardizedFileURL
        }

        internal static func pathsOverlap(
            _ first: URL,
            _ second: URL,
            volumeSupportsCaseSensitiveNames: Bool
        ) -> Bool {
            let firstComponents = normalizedPathComponents(
                of: first,
                volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
            )
            let secondComponents = normalizedPathComponents(
                of: second,
                volumeSupportsCaseSensitiveNames: volumeSupportsCaseSensitiveNames
            )
            return firstComponents.prefix(secondComponents.count).elementsEqual(secondComponents)
                || secondComponents.prefix(firstComponents.count).elementsEqual(firstComponents)
        }

        private static func normalizedPathComponents(
            of url: URL,
            volumeSupportsCaseSensitiveNames: Bool
        ) -> [String] {
            url.standardizedFileURL.pathComponents.map { component in
                let normalized = component.precomposedStringWithCanonicalMapping
                guard !volumeSupportsCaseSensitiveNames else {
                    return normalized
                }
                return portableCollisionKey(for: normalized)
            }
        }

        private func validateDestinationVolumeSemantics(
            of plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            let current = try Self.destinationVolumeSupportsCaseSensitiveNames(
                for: plan.root,
                fileManager: fileManager
            )
            guard current == plan.destinationVolumeSupportsCaseSensitiveNames else {
                throw ArtifactStoreError.destinationVolumeCaseSensitivityChanged(
                    root: plan.root.resolved.path,
                    expected: plan.destinationVolumeSupportsCaseSensitiveNames,
                    actual: current
                )
            }
        }

        private func validateArtifactRoot(
            of plan: CommitPlan,
            fileManager: FileManager
        ) throws {
            let current = try Self.artifactRootURLs(
                for: artifactRoot,
                fileManager: fileManager
            )
            guard current.unresolved.path == plan.root.unresolved.path,
                current.resolved.path == plan.root.resolved.path
            else {
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
            guard let existingKind = try artifactItemKind(at: destination, fileManager: fileManager)
            else {
                return
            }

            switch (entry.kind, existingKind) {
            case (.directory, .directory), (.file, .regularFile):
                return
            case (.directory, .symbolicLink), (.file, .symbolicLink):
                throw ArtifactStoreError.symbolicLinkInArtifactPath(
                    artifactPath: entry.artifact,
                    symbolicLinkPath: destination.path
                )
            case (.directory, .regularFile), (.directory, .other):
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
            case (.file, .other):
                throw ArtifactStoreError.commitDestinationTypeMismatch(
                    artifactPath: entry.artifact,
                    expected: "regular file",
                    actual: "special file"
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
                if fileType == .typeRegular {
                    return .regularFile
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

                let inspection = try cleanupArtifactInspection(
                    for: parent,
                    root: root,
                    fileManager: fileManager
                )
                guard case .leaf(let parentURL, .some(.directory)) = inspection else {
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
