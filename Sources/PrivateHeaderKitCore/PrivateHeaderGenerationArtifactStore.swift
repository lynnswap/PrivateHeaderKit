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
        case invalidReplacementManifest(String)
        case replacementPreparationCleanupFailed(primary: String, cleanup: String)
        case replacementRollbackFailed(primary: String, rollback: String)

        public var description: String {
            switch self {
            case .nonFileArtifactRoot(let artifactRoot):
                "artifact root must be a file URL: \(artifactRoot)"
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
            case .invalidReplacementManifest(let message):
                "invalid artifact replacement manifest: \(message)"
            case .replacementPreparationCleanupFailed(let primary, let cleanup):
                "artifact replacement preparation failed: \(primary); cleanup also failed: \(cleanup)"
            case .replacementRollbackFailed(let primary, let rollback):
                "artifact replacement failed: \(primary); rollback also failed: \(rollback)"
            }
        }
    }

    struct ArtifactStore: Sendable {
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
            internal let runID: PrivateHeaderGeneration.RunID
            internal let targetID: String
            fileprivate let artifactRoot: ArtifactPath
            internal let incomingArtifacts: [ArtifactPath]
            fileprivate let mutationArtifacts: [ArtifactPath]
            fileprivate let backedUpArtifacts: [ArtifactPath]
        }

        private struct ReplacementManifest: Codable {
            let version: Int
            let runID: String
            let targetID: String
            let artifactRoot: String
            let incomingArtifacts: [String]
            let mutationArtifacts: [String]
            let backedUpArtifacts: [String]
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

        internal func prepareCommit(
            stagingDirectory: URL,
            stagedSourceDirectory: URL,
            artifactRoot: ArtifactPath,
            artifacts: [ArtifactPath],
            fileManager: FileManager = .default
        ) throws -> CommitPlan {
            let root = try Self.artifactRootURLs(for: self.artifactRoot)
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
            try preflightCommit(plan, fileManager: fileManager)
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
            _ plan: CommitPlan,
            removing artifactsToRemove: [ArtifactPath],
            runID: PrivateHeaderGeneration.RunID,
            targetID: String,
            at transactionDirectory: URL,
            fileManager: FileManager = .default
        ) throws -> Replacement {
            try preflightCommit(plan, fileManager: fileManager)
            let incomingArtifacts = plan.artifacts.sorted { $0.rawValue < $1.rawValue }
            let mutationArtifacts = Self.cleanupCandidates(
                manifestArtifacts: artifactsToRemove,
                attemptedArtifacts: incomingArtifacts
            )
            _ = try Self.cleanupArtifactInspections(
                for: mutationArtifacts,
                root: plan.root,
                fileManager: fileManager
            )

            let directory = transactionDirectory.standardizedFileURL
            let incomingRoot = directory.appendingPathComponent("incoming", isDirectory: true)
            let backupRoot = directory.appendingPathComponent("backup", isDirectory: true)
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

                let incomingStore = ArtifactStore(artifactRoot: incomingRoot)
                let incomingPlan = try incomingStore.prepareCommit(
                    stagingDirectory: plan.stagingDirectory,
                    stagedSourceDirectory: plan.stagedSourceDirectory,
                    artifactRoot: plan.artifactRoot,
                    artifacts: incomingArtifacts,
                    fileManager: fileManager
                )
                try incomingStore.copy(incomingPlan, fileManager: fileManager)

                let backedUpArtifacts = try backupExistingArtifacts(
                    mutationArtifacts,
                    from: plan.root,
                    to: backupRoot,
                    fileManager: fileManager
                )
                let replacement = Replacement(
                    directory: directory,
                    incomingRoot: incomingRoot,
                    backupRoot: backupRoot,
                    runID: runID,
                    targetID: targetID,
                    artifactRoot: plan.artifactRoot,
                    incomingArtifacts: incomingArtifacts,
                    mutationArtifacts: mutationArtifacts,
                    backedUpArtifacts: backedUpArtifacts
                )
                try writeManifest(for: replacement, fileManager: fileManager)
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
            do {
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
                let incomingArtifactSet = Set(replacement.incomingArtifacts)
                let obsoleteArtifacts = replacement.mutationArtifacts.filter {
                    !incomingArtifactSet.contains($0)
                }
                _ = try cleanupManagedArtifacts(obsoleteArtifacts, fileManager: fileManager)
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
            _ = try cleanupManagedArtifacts(
                replacement.mutationArtifacts,
                fileManager: fileManager
            )
            guard !replacement.backedUpArtifacts.isEmpty else { return }
            let backupSourceDirectory = Self.artifactURL(
                replacement.artifactRoot,
                under: replacement.backupRoot
            )
            let restorePlan = try prepareCommit(
                stagingDirectory: replacement.backupRoot,
                stagedSourceDirectory: backupSourceDirectory,
                artifactRoot: replacement.artifactRoot,
                artifacts: replacement.backedUpArtifacts,
                fileManager: fileManager
            )
            try copy(restorePlan, fileManager: fileManager)
        }

        internal func finalizeReplacement(
            _ replacement: Replacement,
            fileManager: FileManager = .default
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
            for entry in plan.entries where entry.kind == .directory {
                let destination = try revalidate(entry, in: plan, fileManager: fileManager)
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            }
            for entry in plan.entries where entry.kind == .file {
                let destination = try revalidate(entry, in: plan, fileManager: fileManager)
                try ManagedFileSystem.atomicRename(from: entry.source, to: destination)
            }
        }

        private func backupExistingArtifacts(
            _ artifacts: [ArtifactPath],
            from root: ArtifactRootURLs,
            to backupRoot: URL,
            fileManager: FileManager
        ) throws -> [ArtifactPath] {
            var backedUpArtifacts: [ArtifactPath] = []
            for artifact in artifacts {
                let inspection = try Self.preflightCleanupArtifact(
                    for: artifact,
                    root: root,
                    fileManager: fileManager
                )
                switch inspection {
                case .missingParent, .leaf(_, nil):
                    continue
                case .occupiedParent, .symbolicLinkParent:
                    preconditionFailure("preflightCleanupArtifact rejects invalid parents")
                case .leaf(let source, .some(.regularFile)):
                    let destination = Self.artifactURL(artifact, under: backupRoot)
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: source, to: destination)
                    backedUpArtifacts.append(artifact)
                case .leaf(let source, .some(.symbolicLink)):
                    throw ArtifactStoreError.symbolicLinkInArtifactPath(
                        artifactPath: artifact,
                        symbolicLinkPath: source.path
                    )
                case .leaf(_, .some(.directory)), .leaf(_, .some(.other)):
                    throw ArtifactStoreError.commitDestinationTypeMismatch(
                        artifactPath: artifact,
                        expected: "regular file",
                        actual: "non-regular file"
                    )
                }
            }
            return backedUpArtifacts
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
            let manifest = ReplacementManifest(
                version: 1,
                runID: replacement.runID.rawValue,
                targetID: replacement.targetID,
                artifactRoot: replacement.artifactRoot.rawValue,
                incomingArtifacts: replacement.incomingArtifacts.map(\.rawValue),
                mutationArtifacts: replacement.mutationArtifacts.map(\.rawValue),
                backedUpArtifacts: replacement.backedUpArtifacts.map(\.rawValue)
            )
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
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
            let manifest: ReplacementManifest
            do {
                manifest = try JSONDecoder().decode(
                    ReplacementManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "could not decode \(manifestURL.path): \(error)"
                )
            }
            guard manifest.version == 1 else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "unsupported version \(manifest.version) at \(manifestURL.path)"
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
            let backedUpArtifacts = try manifest.backedUpArtifacts.map {
                try ArtifactPath($0)
            }
            let mutationSet = Set(mutationArtifacts)
            guard incomingArtifacts.allSatisfy(mutationSet.contains),
                backedUpArtifacts.allSatisfy(mutationSet.contains)
            else {
                throw ArtifactStoreError.invalidReplacementManifest(
                    "manifest paths do not form one mutation set at \(manifestURL.path)"
                )
            }
            let incomingRoot = directory.appendingPathComponent("incoming", isDirectory: true)
            let backupRoot = directory.appendingPathComponent("backup", isDirectory: true)
            _ = try artifactRootURLs(for: artifactRoot)
            return Replacement(
                directory: directory,
                incomingRoot: incomingRoot,
                backupRoot: backupRoot,
                runID: runID,
                targetID: manifest.targetID,
                artifactRoot: artifactRootPath,
                incomingArtifacts: incomingArtifacts,
                mutationArtifacts: mutationArtifacts,
                backedUpArtifacts: backedUpArtifacts
            )
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
            let root = try artifactRootURLs(for: artifactRoot)
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

            for artifact in cleanupOperationOrder(candidates) {
                guard case .leaf = artifactInspections[artifact]! else {
                    missingArtifacts.append(artifact)
                    continue
                }
                let inspection = try preflightCleanupArtifact(
                    for: artifact,
                    root: root,
                    fileManager: fileManager
                )
                guard case .leaf(let artifactURL, .some(_)) = inspection else {
                    missingArtifacts.append(artifact)
                    continue
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
            try validateArtifactRoot(of: plan)
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

        private func validateArtifactRoot(of plan: CommitPlan) throws {
            let current = try Self.artifactRootURLs(for: artifactRoot)
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
