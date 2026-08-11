import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

enum FileSystemItemKind {
    case absent
    case regularFile
    case directory
    case symbolicLink(String)
    case other
}

struct POSIXRenameError: Error, CustomStringConvertible {
    let source: URL
    let destination: URL
    let code: Int32

    var description: String {
        "atomic rename failed from \(source.path) to \(destination.path): errno \(code)"
    }
}

func fileSystemItemKind(
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

    var legacyMigrationIntentURL: URL {
        installRoot.appendingPathComponent(
            ".legacy-migration-intent.json",
            isDirectory: false
        )
    }

    var publicCommandURL: URL {
        binDir.appendingPathComponent(
            InstallArtifactName.publicCommand.rawValue,
            isDirectory: false
        )
    }

    var rawDumpHelperURL: URL {
        installRoot.appendingPathComponent(
            InstallArtifactName.rawDumpHelper.rawValue,
            isDirectory: false
        )
    }

    var simulatorHelperURL: URL {
        installRoot.appendingPathComponent(
            InstallArtifactName.simulatorHelper.rawValue,
            isDirectory: false
        )
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

func resolveInstallLayout(
    prefix: String?,
    bindir: String?,
    fileManager: FileManager = .default
) throws -> InstallLayout {
    let resolvedPrefix: URL
    let resolvedBinDir: URL
    if let bindir {
        resolvedBinDir = try canonicalDirectoryURL(
            URL(
                fileURLWithPath: PathUtils.expandTilde(bindir),
                isDirectory: true
            ),
            fileManager: fileManager
        )
        resolvedPrefix = resolvedBinDir.deletingLastPathComponent()
    } else {
        let prefix = prefix ?? "~/.local"
        resolvedPrefix = try canonicalDirectoryURL(
            URL(
                fileURLWithPath: PathUtils.expandTilde(prefix),
                isDirectory: true
            ),
            fileManager: fileManager
        )
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

func resolveBinDir(prefix: String?, bindir: String?) throws -> URL {
    try resolveInstallLayout(prefix: prefix, bindir: bindir).binDir
}

final class InstallLock {
#if canImport(Darwin)
    private var descriptor: Int32?

    init(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        let installRoot = url.deletingLastPathComponent()
        switch try fileSystemItemKind(at: installRoot, fileManager: fileManager) {
        case .directory:
            break
        case .absent:
            throw InstallError.message(
                "install root does not exist before lock acquisition: \(installRoot.path)"
            )
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
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw InstallError.message(
                "failed to open install lock at \(url.path): errno \(errno)"
            )
        }
        var lockMetadata = stat()
        guard Darwin.fstat(descriptor, &lockMetadata) == 0 else {
            let lockErrno = errno
            _ = Darwin.close(descriptor)
            throw InstallError.message(
                "failed to inspect install lock at \(url.path): errno \(lockErrno)"
            )
        }
        guard lockMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = Darwin.close(descriptor)
            throw InstallError.message(
                "install lock is not a regular file at \(url.path)"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            _ = Darwin.close(descriptor)
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

    func close() {
        guard let descriptor else {
            return
        }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    deinit {
        close()
    }
#else
    init(at url: URL, fileManager: FileManager = .default) throws {
        throw InstallError.message(
            "install locking is unavailable on this platform: \(url.path)"
        )
    }
#endif
}

extension VersionCohortInstaller {
    func validateManagedInstallRootPath(
        requireInstallRoot: Bool
    ) throws {
        let libexecDirectory = layout.prefix.appendingPathComponent(
            "libexec",
            isDirectory: true
        )
        let expectedInstallRoot = libexecDirectory.appendingPathComponent(
            "privateheaderkit",
            isDirectory: true
        ).standardizedFileURL
        guard layout.installRoot.standardizedFileURL == expectedInstallRoot else {
            throw InstallError.message(
                "install root is outside the managed prefix layout: \(layout.installRoot.path)"
            )
        }

        let managedDirectories: [(url: URL, label: String)] = [
            (layout.prefix, "install prefix"),
            (libexecDirectory, "managed libexec directory"),
            (layout.installRoot, "install root"),
        ]
        for managedDirectory in managedDirectories {
            switch try fileSystemItemKind(
                at: managedDirectory.url,
                fileManager: fileManager
            ) {
            case .directory:
                continue
            case .absent:
                if requireInstallRoot,
                   managedDirectory.url.standardizedFileURL
                    == layout.installRoot.standardizedFileURL
                {
                    throw InstallError.message(
                        "install root was not created as a real directory: \(layout.installRoot.path)"
                    )
                }
            case .symbolicLink:
                throw InstallError.message(
                    "\(managedDirectory.label) must not be a symbolic link: \(managedDirectory.url.path)"
                )
            case .regularFile, .other:
                throw InstallError.message(
                    "\(managedDirectory.label) is not a real directory: \(managedDirectory.url.path)"
                )
            }
        }
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

    func pathsReferenceSameFile(_ lhs: URL, _ rhs: URL) throws -> Bool {
#if canImport(Darwin)
        func metadata(at url: URL) throws -> stat {
            var metadata = stat()
            let result = url.path.withCString { path in
                Darwin.fstatat(AT_FDCWD, path, &metadata, 0)
            }
            guard result == 0 else {
                throw InstallError.message(
                    "failed to resolve installed file at \(url.path): errno \(errno)"
                )
            }
            return metadata
        }
        let lhsMetadata = try metadata(at: lhs)
        let rhsMetadata = try metadata(at: rhs)
        return lhsMetadata.st_dev == rhsMetadata.st_dev
            && lhsMetadata.st_ino == rhsMetadata.st_ino
#else
        throw InstallError.message(
            "installed file identity is unavailable on this platform"
        )
#endif
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
            throw POSIXRenameError(
                source: source,
                destination: destination,
                code: errno
            )
        }
#else
        throw InstallError.message("atomic rename is unavailable on this platform")
#endif
    }

    func publishCohortExclusively(source: URL, destination: URL) throws {
#if canImport(Darwin)
        let result = source.path.withCString { sourcePointer in
            destination.path.withCString { destinationPointer in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePointer,
                    AT_FDCWD,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXRenameError(
                source: source,
                destination: destination,
                code: errno
            )
        }
#else
        throw InstallError.message(
            "exclusive cohort publication is unavailable on this platform"
        )
#endif
    }

    func pathExists(_ url: URL) throws -> Bool {
        if case .absent = try fileSystemItemKind(at: url, fileManager: fileManager) {
            return false
        }
        return true
    }
}

private func canonicalDirectoryURL(
    _ url: URL,
    fileManager: FileManager
) throws -> URL {
#if canImport(Darwin)
    var existingAncestor = url.standardizedFileURL
    var missingComponents: [String] = []

    while true {
        switch try fileSystemItemKind(at: existingAncestor, fileManager: fileManager) {
        case .absent:
            guard existingAncestor.path != "/" else {
                throw InstallError.message(
                    "failed to resolve install path: \(url.path)"
                )
            }
            missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
            existingAncestor.deleteLastPathComponent()
        case .regularFile where !missingComponents.isEmpty,
             .other where !missingComponents.isEmpty:
            throw InstallError.message(
                "install path has a non-directory ancestor: \(existingAncestor.path)"
            )
        case .regularFile, .other, .directory, .symbolicLink:
            break
        }
        if case .absent = try fileSystemItemKind(
            at: existingAncestor,
            fileManager: fileManager
        ) {
            continue
        }
        break
    }

    let resolvedAncestor: URL = try existingAncestor.path.withCString { path in
        guard let resolvedPath = Darwin.realpath(path, nil) else {
            throw InstallError.message(
                "failed to resolve install path at \(existingAncestor.path): errno \(errno)"
            )
        }
        defer { Darwin.free(resolvedPath) }
        return URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: true
        )
    }

    guard case .directory = try fileSystemItemKind(
        at: resolvedAncestor,
        fileManager: fileManager
    ) else {
        throw InstallError.message(
            "install path is not rooted in a real directory: \(url.path)"
        )
    }

    return missingComponents.reduce(resolvedAncestor) { partial, component in
        partial.appendingPathComponent(component, isDirectory: true)
    }.standardizedFileURL
#else
    throw InstallError.message(
        "install path canonicalization is unavailable on this platform: \(url.path)"
    )
#endif
}
