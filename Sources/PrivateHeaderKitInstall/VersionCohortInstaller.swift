import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

private enum FileSystemItemKind {
    case absent
    case regularFile
    case directory
    case symbolicLink(String)
    case other
}

private func fileSystemItemKind(
    at url: URL,
    fileManager: FileManager
) throws -> FileSystemItemKind {
#if canImport(Darwin)
    var metadata = stat()
    let result = url.path.withCString { path in
        Darwin.lstat(path, &metadata)
    }
    if result != 0 {
        let failure = errno
        if failure == ENOENT {
            return .absent
        }
        throw InstallError.message(
            "failed to inspect install path at \(url.path): errno \(failure)"
        )
    }

    switch metadata.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFREG):
        return .regularFile
    case mode_t(S_IFDIR):
        return .directory
    case mode_t(S_IFLNK):
        do {
            return .symbolicLink(
                try fileManager.destinationOfSymbolicLink(atPath: url.path)
            )
        } catch {
            throw InstallError.message(
                "failed to read symbolic link at \(url.path): \(error)"
            )
        }
    default:
        return .other
    }
#else
    throw InstallError.message(
        "install path inspection is unavailable on this platform: \(url.path)"
    )
#endif
}

struct InstallLayout: Equatable, Sendable {
    let prefix: URL
    let binDir: URL
    let installRoot: URL

    var versionsDirectory: URL {
        installRoot.appendingPathComponent("versions", isDirectory: true)
    }

    var currentURL: URL {
        installRoot.appendingPathComponent("current", isDirectory: false)
    }

    var lockURL: URL {
        installRoot.appendingPathComponent("install.lock", isDirectory: false)
    }

    var publicCommandURL: URL {
        binDir.appendingPathComponent(InstallArtifactName.publicCommand.rawValue, isDirectory: false)
    }

    var rawDumpHelperURL: URL {
        installRoot.appendingPathComponent(InstallArtifactName.rawDumpHelper.rawValue, isDirectory: false)
    }

    var simulatorHelperURL: URL {
        installRoot.appendingPathComponent(InstallArtifactName.simulatorHelper.rawValue, isDirectory: false)
    }

    func cohortDirectory(for manifest: ReleaseManifest) -> URL {
        versionsDirectory.appendingPathComponent(manifest.cohort, isDirectory: true)
    }

    func installedArtifactURL(
        _ artifact: InstallArtifactName,
        manifest: ReleaseManifest
    ) -> URL {
        cohortDirectory(for: manifest)
            .appendingPathComponent(artifact.rawValue, isDirectory: false)
    }
}

func resolveInstallLayout(prefix: String?, bindir: String?) -> InstallLayout {
    let resolvedPrefix: URL
    let resolvedBinDir: URL
    if let bindir {
        resolvedBinDir = URL(
            fileURLWithPath: PathUtils.expandTilde(bindir),
            isDirectory: true
        ).standardizedFileURL
        resolvedPrefix = resolvedBinDir.deletingLastPathComponent()
    } else {
        let prefix = prefix ?? "~/.local"
        resolvedPrefix = URL(
            fileURLWithPath: PathUtils.expandTilde(prefix),
            isDirectory: true
        ).standardizedFileURL
        resolvedBinDir = resolvedPrefix.appendingPathComponent("bin", isDirectory: true)
    }
    return InstallLayout(
        prefix: resolvedPrefix,
        binDir: resolvedBinDir,
        installRoot: resolvedPrefix.appendingPathComponent(
            "libexec/privateheaderkit",
            isDirectory: true
        )
    )
}

func resolveBinDir(prefix: String?, bindir: String?) -> URL {
    resolveInstallLayout(prefix: prefix, bindir: bindir).binDir
}

struct ReleaseCohort {
    let manifest: ReleaseManifest
    let artifactURLs: [InstallArtifactName: URL]

    init(
        manifest: ReleaseManifest,
        artifactURLs: [InstallArtifactName: URL]
    ) throws {
        try manifest.validate()
        let expected = Set(InstallArtifactName.allCases)
        guard Set(artifactURLs.keys) == expected,
              artifactURLs.count == expected.count
        else {
            throw InstallError.message(
                "release cohort must contain exactly: \(expected.map(\.rawValue).sorted().joined(separator: ", "))"
            )
        }
        self.manifest = manifest
        self.artifactURLs = artifactURLs
    }

    static func read(
        from directory: URL,
        fileManager: FileManager = .default
    ) throws -> ReleaseCohort {
        guard case .directory = try fileSystemItemKind(
            at: directory,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "release cohort is not a real directory: \(directory.path)"
            )
        }
        let expectedEntries = Set(
            InstallArtifactName.allCases.map(\.rawValue) + [ReleaseManifest.fileName]
        )
        let actualEntries = Set(
            try fileManager.contentsOfDirectory(atPath: directory.path)
        )
        guard actualEntries == expectedEntries else {
            throw InstallError.message(
                "release cohort entries do not match the required set; expected \(expectedEntries.sorted()), got \(actualEntries.sorted())"
            )
        }

        let manifestURL = directory.appendingPathComponent(
            ReleaseManifest.fileName,
            isDirectory: false
        )
        guard case .regularFile = try fileSystemItemKind(
            at: manifestURL,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "release manifest is not a regular file: \(manifestURL.path)"
            )
        }
        let manifest = try ReleaseManifest.read(from: manifestURL)
        return try ReleaseCohort(
            manifest: manifest,
            artifactURLs: Dictionary(
                uniqueKeysWithValues: InstallArtifactName.allCases.map { artifact in
                    (
                        artifact,
                        directory.appendingPathComponent(artifact.rawValue, isDirectory: false)
                    )
                }
            )
        )
    }
}

enum InstallFaultPoint: Equatable, Sendable {
    case lockAcquired
    case preflightComplete
    case artifactStaged(InstallArtifactName)
    case stagingValidated
    case cohortPublished
    case currentSwitched
    case stableCommandSwitched
    case legacyCleanupStarted
}

typealias InstallFaultInjector = (InstallFaultPoint) throws -> Void

struct InstallResult: Equatable, Sendable {
    let cohort: String
    let cohortDirectory: URL
    let publicCommandURL: URL
    let reusedExistingCohort: Bool
    let cleanupWarnings: [String]
}

final class InstallLock {
#if canImport(Darwin)
    private let descriptor: Int32

    init(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        let installRoot = url.deletingLastPathComponent()
        switch try fileSystemItemKind(at: installRoot, fileManager: fileManager) {
        case .absent:
            try fileManager.createDirectory(
                at: installRoot,
                withIntermediateDirectories: true
            )
        case .directory:
            break
        case .symbolicLink:
            throw InstallError.message(
                "install root must not be a symbolic link: \(installRoot.path)"
            )
        case .regularFile, .other:
            throw InstallError.message(
                "install root is not a real directory: \(installRoot.path)"
            )
        }
        guard case .directory = try fileSystemItemKind(
            at: installRoot,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "install root is not a real directory: \(installRoot.path)"
            )
        }
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw InstallError.message(
                "failed to open install lock at \(url.path): errno \(errno)"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            _ = close(descriptor)
            if lockErrno == EWOULDBLOCK || lockErrno == EAGAIN {
                throw InstallError.message(
                    "another PrivateHeaderKit installation is already running for \(url.deletingLastPathComponent().path)"
                )
            }
            throw InstallError.message(
                "failed to acquire install lock at \(url.path): errno \(lockErrno)"
            )
        }
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
#else
    init(at url: URL, fileManager: FileManager = .default) throws {
        throw InstallError.message(
            "install locking is unavailable on this platform: \(url.path)"
        )
    }
#endif
}

struct VersionCohortInstaller {
    let layout: InstallLayout
    let fileManager: FileManager
    let inspectArtifact: ReleaseArtifactInspector
    let faultInjector: InstallFaultInjector
    let outputLogger: (String) -> Void

    init(
        layout: InstallLayout,
        fileManager: FileManager = .default,
        inspectArtifact: @escaping ReleaseArtifactInspector,
        faultInjector: @escaping InstallFaultInjector = { _ in },
        outputLogger: @escaping (String) -> Void = { print($0) }
    ) {
        self.layout = layout
        self.fileManager = fileManager
        self.inspectArtifact = inspectArtifact
        self.faultInjector = faultInjector
        self.outputLogger = outputLogger
    }

    func withInstallLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        try validateOwnedDirectoryIfPresent(layout.installRoot, label: "install root")
        let lock = try InstallLock(at: layout.lockURL, fileManager: fileManager)
        _ = lock
        try validateOwnedDirectoryIfPresent(layout.installRoot, label: "install root")
        try validateOwnedDirectoryIfPresent(layout.versionsDirectory, label: "versions path")
        try faultInjector(.lockAcquired)
        return try operation()
    }

    func install(_ cohort: ReleaseCohort) throws -> InstallResult {
        try withInstallLock {
            try installLocked(cohort)
        }
    }

    func installLocked(_ cohort: ReleaseCohort) throws -> InstallResult {
        try preflight(cohort)
        try faultInjector(.preflightComplete)
        try validateOwnedDirectoryIfPresent(layout.installRoot, label: "install root")
        try validateOwnedDirectoryIfPresent(layout.versionsDirectory, label: "versions path")
        let currentBeforeInstall = try currentPathSnapshot()
        let hadLegacyDirectLayout = try isLegacyDirectLayout()
        if hadLegacyDirectLayout,
           case .symbolicLink = currentBeforeInstall
        {
            throw InstallError.message(
                "legacy direct binaries and a managed current cohort both exist; refusing ambiguous migration"
            )
        }
        try validateManagedDestinations(
            allowLegacyDirectLayout: hadLegacyDirectLayout,
            current: currentBeforeInstall
        )

        try fileManager.createDirectory(
            at: layout.versionsDirectory,
            withIntermediateDirectories: true
        )
        try validateOwnedDirectoryIfPresent(
            layout.versionsDirectory,
            label: "versions path"
        )
        try fileManager.createDirectory(
            at: layout.binDir,
            withIntermediateDirectories: true
        )

        let stagingDirectory = layout.versionsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                do {
                    try fileManager.removeItem(at: stagingDirectory)
                } catch {
                    outputLogger(
                        "warning: failed to remove install staging directory at \(stagingDirectory.path): \(error)"
                    )
                }
            }
        }

        for artifact in InstallArtifactName.allCases.sorted() {
            let sourceURL = try sourceURL(for: artifact, in: cohort)
            let destinationURL = stagingDirectory.appendingPathComponent(
                artifact.rawValue,
                isDirectory: false
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: destinationURL.path
            )
            try faultInjector(.artifactStaged(artifact))
        }
        try cohort.manifest.encoded().write(
            to: stagingDirectory.appendingPathComponent(
                ReleaseManifest.fileName,
                isDirectory: false
            ),
            options: [.atomic]
        )
        try validateDirectory(
            stagingDirectory,
            expectedManifest: cohort.manifest
        )
        try faultInjector(.stagingValidated)

        let finalDirectory = layout.cohortDirectory(for: cohort.manifest)
        var reusedExistingCohort = false
        if try pathExists(finalDirectory) {
            try validateDirectory(
                finalDirectory,
                expectedManifest: cohort.manifest
            )
            reusedExistingCohort = true
        } else {
            do {
                try atomicRename(source: stagingDirectory, destination: finalDirectory)
                shouldRemoveStaging = false
            } catch {
                guard try pathExists(finalDirectory) else {
                    throw error
                }
                try validateDirectory(
                    finalDirectory,
                    expectedManifest: cohort.manifest
                )
                reusedExistingCohort = true
            }
        }
        try faultInjector(.cohortPublished)

        let previousCurrent = try currentPathSnapshot()
        let previousPublicCommand = try publicCommandPathSnapshot(
            allowLegacyDirectLayout: hadLegacyDirectLayout
        )
        var legacyPublicBackup: URL?

        do {
            try atomicReplaceSymlink(
                at: layout.currentURL,
                destination: "versions/\(cohort.manifest.cohort)"
            )
            try faultInjector(.currentSwitched)

            if case .regularFile = previousPublicCommand {
                let backup = layout.installRoot.appendingPathComponent(
                    ".legacy-public-\(UUID().uuidString)",
                    isDirectory: false
                )
                try fileManager.copyItem(at: layout.publicCommandURL, to: backup)
                legacyPublicBackup = backup
            }
            try atomicReplaceSymlink(
                at: layout.publicCommandURL,
                destination: "../libexec/privateheaderkit/current/privateheaderkit"
            )
            try faultInjector(.stableCommandSwitched)
            try verifyActiveCohort(cohort.manifest)
        } catch {
            let restorationError = restoreAfterActivationFailure(
                previousCurrent: previousCurrent,
                previousPublicCommand: previousPublicCommand,
                legacyPublicBackup: legacyPublicBackup
            )
            if let restorationError {
                throw InstallError.message(
                    "installation failed: \(error); restoring the previous install also failed: \(restorationError)"
                )
            }
            throw error
        }

        var cleanupWarnings: [String] = []
        if let legacyPublicBackup {
            do {
                try fileManager.removeItem(at: legacyPublicBackup)
            } catch {
                cleanupWarnings.append(
                    "failed to remove legacy public-command backup at \(legacyPublicBackup.path): \(error)"
                )
            }
        }
        if hadLegacyDirectLayout {
            do {
                try faultInjector(.legacyCleanupStarted)
                try cleanupLegacyDirectLayout()
            } catch {
                cleanupWarnings.append(
                    "new cohort is active, but legacy helper cleanup failed: \(error)"
                )
            }
        }
        for warning in cleanupWarnings {
            outputLogger("warning: \(warning)")
        }

        outputLogger(
            "Installed PrivateHeaderKit \(cohort.manifest.version) (\(cohort.manifest.commit))"
        )
        outputLogger("Active cohort: \(finalDirectory.path)")
        outputLogger("Command: \(layout.publicCommandURL.path)")
        return InstallResult(
            cohort: cohort.manifest.cohort,
            cohortDirectory: finalDirectory,
            publicCommandURL: layout.publicCommandURL,
            reusedExistingCohort: reusedExistingCohort,
            cleanupWarnings: cleanupWarnings
        )
    }
}

private extension VersionCohortInstaller {
    enum ManagedPathSnapshot {
        case absent
        case symbolicLink(String)
        case regularFile
    }

    func preflight(_ cohort: ReleaseCohort) throws {
        try cohort.manifest.validate()
        for artifact in InstallArtifactName.allCases {
            let sourceURL = try sourceURL(for: artifact, in: cohort)
            let expected = try cohort.manifest.artifact(named: artifact)
            let actual = try inspectArtifact(artifact, sourceURL)
            try validate(
                actual,
                expected: expected,
                path: sourceURL.path
            )
        }
    }

    func sourceURL(
        for artifact: InstallArtifactName,
        in cohort: ReleaseCohort
    ) throws -> URL {
        guard let url = cohort.artifactURLs[artifact] else {
            throw InstallError.message(
                "missing install artifact: \(artifact.rawValue)"
            )
        }
        return url
    }

    func validateDirectory(
        _ directory: URL,
        expectedManifest: ReleaseManifest
    ) throws {
        let installed = try ReleaseCohort.read(
            from: directory,
            fileManager: fileManager
        )
        guard installed.manifest == expectedManifest else {
            if installed.manifest.cohort == expectedManifest.cohort,
               installed.manifest.commit != expectedManifest.commit
            {
                throw InstallError.message(
                    "binary cohort collision with different provenance at \(directory.path): existing commit \(installed.manifest.commit), requested commit \(expectedManifest.commit)"
                )
            }
            throw InstallError.message(
                "immutable cohort already exists with different contents: \(directory.path)"
            )
        }
        try preflight(installed)
    }

    func validate(
        _ actual: ReleaseArtifactInspection,
        expected: ReleaseArtifactRecord,
        path: String
    ) throws {
        guard actual.sha256 == expected.sha256 else {
            throw InstallError.message(
                "SHA-256 mismatch for \(expected.name.rawValue) at \(path)"
            )
        }
        guard actual.architectures == expected.architectures.sorted() else {
            throw InstallError.message(
                "architecture mismatch for \(expected.name.rawValue): expected \(expected.architectures.sorted()), got \(actual.architectures)"
            )
        }
        guard actual.platform == expected.platform else {
            throw InstallError.message(
                "platform mismatch for \(expected.name.rawValue): expected \(expected.platform.rawValue), got \(actual.platform.rawValue)"
            )
        }
    }

    func validateManagedDestinations(
        allowLegacyDirectLayout: Bool,
        current: ManagedPathSnapshot
    ) throws {
        if case .absent = try fileSystemItemKind(
            at: layout.publicCommandURL,
            fileManager: fileManager
        ) {
            return
        } else {
            let publicCommand = try publicCommandPathSnapshot(
                allowLegacyDirectLayout: allowLegacyDirectLayout
            )
            if case .symbolicLink = publicCommand,
               case .absent = current
            {
                throw InstallError.message(
                    "stable public command exists without a managed current cohort: \(layout.publicCommandURL.path)"
                )
            }
        }
    }

    func currentPathSnapshot() throws -> ManagedPathSnapshot {
        let snapshot = try managedPathSnapshot(
            at: layout.currentURL,
            allowRegularFile: false,
            allowedSymbolicLink: isManagedCurrentDestination
        )
        if case .symbolicLink(let destination) = snapshot {
            try validateManagedCurrentCohort(destination: destination)
        }
        return snapshot
    }

    func publicCommandPathSnapshot(
        allowLegacyDirectLayout: Bool
    ) throws -> ManagedPathSnapshot {
        try managedPathSnapshot(
            at: layout.publicCommandURL,
            allowRegularFile: allowLegacyDirectLayout,
            allowedSymbolicLink: {
                $0 == "../libexec/privateheaderkit/current/privateheaderkit"
            }
        )
    }

    func managedPathSnapshot(
        at url: URL,
        allowRegularFile: Bool,
        allowedSymbolicLink: (String) -> Bool
    ) throws -> ManagedPathSnapshot {
        switch try fileSystemItemKind(at: url, fileManager: fileManager) {
        case .absent:
            return .absent
        case .symbolicLink(let destination):
            guard allowedSymbolicLink(destination) else {
                throw InstallError.message(
                    "refusing to replace unmanaged symbolic link at \(url.path): \(destination)"
                )
            }
            return .symbolicLink(destination)
        case .regularFile:
            if allowRegularFile {
                return .regularFile
            }
            throw InstallError.message(
                "refusing to replace unmanaged install path: \(url.path)"
            )
        case .directory, .other:
            throw InstallError.message(
                "refusing to replace unmanaged install path: \(url.path)"
            )
        }
    }

    func isLegacyDirectLayout() throws -> Bool {
        for url in [
            layout.publicCommandURL,
            layout.rawDumpHelperURL,
            layout.simulatorHelperURL,
        ] {
            guard case .regularFile = try fileSystemItemKind(
                at: url,
                fileManager: fileManager
            ) else {
                return false
            }
        }
        return true
    }

    func isManagedCurrentDestination(_ destination: String) -> Bool {
        guard destination.hasPrefix("versions/") else {
            return false
        }
        let cohort = String(destination.dropFirst("versions/".count))
        guard !cohort.isEmpty, cohort != ".", cohort != "..",
              !cohort.contains("/")
        else {
            return false
        }
        return cohort.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "."
                || scalar == "_"
                || scalar == "+"
                || scalar == "-"
        }
    }

    func validateManagedCurrentCohort(destination: String) throws {
        let cohortIdentifier = String(destination.dropFirst("versions/".count))
        let cohortDirectory = layout.versionsDirectory.appendingPathComponent(
            cohortIdentifier,
            isDirectory: true
        )
        guard case .directory = try fileSystemItemKind(
            at: cohortDirectory,
            fileManager: fileManager
        ) else {
            throw InstallError.message(
                "current pointer references a missing cohort: \(destination)"
            )
        }
        let cohort = try ReleaseCohort.read(
            from: cohortDirectory,
            fileManager: fileManager
        )
        guard cohort.manifest.cohort == cohortIdentifier else {
            throw InstallError.message(
                "current pointer cohort does not match its release manifest: \(destination)"
            )
        }
        try preflight(cohort)
    }

    func validateOwnedDirectoryIfPresent(
        _ url: URL,
        label: String
    ) throws {
        switch try fileSystemItemKind(at: url, fileManager: fileManager) {
        case .absent:
            return
        case .directory:
            return
        case .symbolicLink:
            throw InstallError.message(
                "\(label) must not be a symbolic link: \(url.path)"
            )
        case .regularFile, .other:
            throw InstallError.message(
                "\(label) is not a real directory: \(url.path)"
            )
        }
    }

    func verifyActiveCohort(_ manifest: ReleaseManifest) throws {
        let expectedCurrent = "versions/\(manifest.cohort)"
        let currentDestination = try fileManager.destinationOfSymbolicLink(
            atPath: layout.currentURL.path
        )
        guard currentDestination == expectedCurrent else {
            throw InstallError.message(
                "current pointer verification failed: expected \(expectedCurrent), got \(currentDestination)"
            )
        }
        let expectedPublicDestination = "../libexec/privateheaderkit/current/privateheaderkit"
        let publicDestination = try fileManager.destinationOfSymbolicLink(
            atPath: layout.publicCommandURL.path
        )
        guard publicDestination == expectedPublicDestination else {
            throw InstallError.message(
                "public command pointer verification failed: expected \(expectedPublicDestination), got \(publicDestination)"
            )
        }

        let resolvedPublic = layout.publicCommandURL.resolvingSymlinksInPath().standardizedFileURL
        let expectedPublic = layout.installedArtifactURL(
            .publicCommand,
            manifest: manifest
        ).standardizedFileURL
        guard resolvedPublic.path == expectedPublic.path else {
            throw InstallError.message(
                "public command does not resolve to the active cohort: \(resolvedPublic.path)"
            )
        }
        try validateDirectory(
            layout.cohortDirectory(for: manifest),
            expectedManifest: manifest
        )
    }

    func cleanupLegacyDirectLayout() throws {
        let helpers = [layout.rawDumpHelperURL, layout.simulatorHelperURL]
        for url in helpers {
            guard case .regularFile = try fileSystemItemKind(
                at: url,
                fileManager: fileManager
            ) else {
                throw InstallError.message(
                    "legacy helper changed before cleanup; refusing to remove: \(url.path)"
                )
            }
        }
        for url in helpers {
            try fileManager.removeItem(at: url)
        }
    }

    func restoreAfterActivationFailure(
        previousCurrent: ManagedPathSnapshot,
        previousPublicCommand: ManagedPathSnapshot,
        legacyPublicBackup: URL?
    ) -> Error? {
        do {
            try restore(
                previousCurrent,
                at: layout.currentURL,
                regularFileBackup: nil
            )
            try restore(
                previousPublicCommand,
                at: layout.publicCommandURL,
                regularFileBackup: legacyPublicBackup
            )
            return nil
        } catch {
            return error
        }
    }

    func restore(
        _ snapshot: ManagedPathSnapshot,
        at url: URL,
        regularFileBackup: URL?
    ) throws {
        switch snapshot {
        case .absent:
            switch try fileSystemItemKind(at: url, fileManager: fileManager) {
            case .absent:
                return
            case .symbolicLink(let destination)
                where isManagedCurrentDestination(destination)
                    || destination == "../libexec/privateheaderkit/current/privateheaderkit":
                try fileManager.removeItem(at: url)
            case .regularFile, .directory, .symbolicLink, .other:
                throw InstallError.message(
                    "refusing to remove an unexpected path while restoring: \(url.path)"
                )
            }
        case .symbolicLink(let destination):
            try atomicReplaceSymlink(at: url, destination: destination)
        case .regularFile:
            guard let regularFileBackup else {
                // The regular file has not been replaced yet.
                return
            }
            try atomicRename(source: regularFileBackup, destination: url)
        }
    }

    func atomicReplaceSymlink(
        at url: URL,
        destination: String
    ) throws {
#if canImport(Darwin)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let symlinkResult = destination.withCString { destinationPointer in
            temporaryURL.path.withCString { pathPointer in
                Darwin.symlink(destinationPointer, pathPointer)
            }
        }
        guard symlinkResult == 0 else {
            throw InstallError.message(
                "failed to create temporary symlink at \(temporaryURL.path): errno \(errno)"
            )
        }
        do {
            try atomicRename(source: temporaryURL, destination: url)
        } catch {
            do {
                try fileManager.removeItem(at: temporaryURL)
            } catch let cleanupError {
                outputLogger(
                    "warning: failed to remove temporary symlink at \(temporaryURL.path): \(cleanupError)"
                )
            }
            throw error
        }
#else
        throw InstallError.message(
            "atomic symlink publication is unavailable on this platform"
        )
#endif
    }

    func atomicRename(source: URL, destination: URL) throws {
#if canImport(Darwin)
        let result = source.path.withCString { sourcePointer in
            destination.path.withCString { destinationPointer in
                Darwin.rename(sourcePointer, destinationPointer)
            }
        }
        guard result == 0 else {
            throw InstallError.message(
                "atomic rename failed from \(source.path) to \(destination.path): errno \(errno)"
            )
        }
#else
        throw InstallError.message("atomic rename is unavailable on this platform")
#endif
    }

    func pathExists(_ url: URL) throws -> Bool {
        if case .absent = try fileSystemItemKind(at: url, fileManager: fileManager) {
            return false
        }
        return true
    }
}
