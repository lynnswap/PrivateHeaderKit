import Foundation
import PrivateHeaderKitExecutableResolution

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension PrivateHeaderGeneration {
    enum TargetDiscovery {
        static func discover(
            in systemRoot: URL,
            includeNestedChildren: Bool = true,
            sharedCacheImagePaths: [String] = [],
            fileManager: FileManager = .default
        ) throws -> Catalog {
            let root = systemRoot.standardizedFileURL
            guard try isDirectory(root, fileManager: fileManager) else {
                throw Error.missingSystemRoot(root.path)
            }
            let sharedCacheImages = SharedCacheImageIndex(paths: sharedCacheImagePaths)

            var groups: [DiscoveredTargetGroup] = []
            groups += try discoverFrameworks(
                in: root,
                location: .publicFramework,
                includeNestedChildren: includeNestedChildren,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            )
            groups += try discoverFrameworks(
                in: root,
                location: .privateFramework,
                includeNestedChildren: includeNestedChildren,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            )
            groups += try discoverSystemLibraryBundles(
                in: root,
                includeNestedChildren: includeNestedChildren,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            )
            groups += try discoverUsrLibDylibs(
                in: root,
                sharedCacheImagePaths: sharedCacheImagePaths,
                fileManager: fileManager
            )

            return Catalog(groups: groups)
        }
    }
}

extension PrivateHeaderGeneration.TargetDiscovery {
    struct Catalog: Hashable, Sendable {
        let groups: [DiscoveredTargetGroup]

        var resolverCandidates: [PrivateHeaderGeneration.TargetCandidate] {
            groups.map(\.selectionCandidate)
        }

        var resolver: PrivateHeaderGeneration.TargetResolver {
            PrivateHeaderGeneration.TargetResolver(candidates: resolverCandidates)
        }

        var allExecutionTargets: [DiscoveredTarget] {
            groups.flatMap(\.executionTargets)
        }
    }

    struct DiscoveredTargetGroup: Hashable, Sendable {
        let selectionCandidate: PrivateHeaderGeneration.TargetCandidate
        let primaryTarget: DiscoveredTarget?
        let childTargets: [DiscoveredTarget]

        var executionTargets: [DiscoveredTarget] {
            primaryTarget.map { [$0] + childTargets } ?? childTargets
        }
    }

    struct DiscoveredTarget: Hashable, Sendable {
        let candidate: PrivateHeaderGeneration.TargetCandidate
        let source: SourceMetadata
        let artifactRoot: PrivateHeaderGeneration.ArtifactPath
        let inputPath: String
        let runtimeInputPath: String
    }

    enum SourceMetadata: Hashable, Sendable {
        case framework(FrameworkSource)
        case systemLibraryBundle(SystemLibraryBundleSource)
        case usrLibDylib(UsrLibDylibSource)

        var runtimeInputPath: String {
            switch self {
            case .framework(let source):
                "/System/Library/\(source.systemLibraryRelativePath)"
            case .systemLibraryBundle(let source):
                "/System/Library/\(source.relativePath)"
            case .usrLibDylib(let source):
                "/usr/lib/\(source.name)"
            }
        }
    }

    struct FrameworkSource: Hashable, Sendable {
        let location: FrameworkLocation
        let bundleName: String

        var frameworkName: String {
            bundleName.removingCaseInsensitiveSuffix(".framework")
        }

        var systemLibraryRelativePath: String {
            "\(location.systemLibraryDirectoryName)/\(bundleName)"
        }
    }

    enum FrameworkLocation: Hashable, Sendable {
        case publicFramework
        case privateFramework

        var systemLibraryDirectoryName: String {
            switch self {
            case .publicFramework:
                "Frameworks"
            case .privateFramework:
                "PrivateFrameworks"
            }
        }

        var targetKind: PrivateHeaderGeneration.TargetKind {
            switch self {
            case .publicFramework:
                .framework
            case .privateFramework:
                .privateFramework
            }
        }

        var identifierPrefix: String {
            switch self {
            case .publicFramework:
                "framework"
            case .privateFramework:
                "private-framework"
            }
        }
    }

    struct SystemLibraryBundleSource: Hashable, Sendable {
        let relativePath: String
        let bundleKind: BundleKind
        let role: BundleRole
    }

    enum BundleRole: Hashable, Sendable {
        case topLevel
        case nestedChild(parentRelativePath: String)
    }

    enum BundleKind: String, Hashable, Sendable {
        case app
        case bundle
        case xpc
        case appex

        init?(pathExtension: String) {
            self.init(rawValue: pathExtension.lowercased())
        }
    }

    struct UsrLibDylibSource: Hashable, Sendable {
        let name: String
    }

    enum Error: Swift.Error, Equatable, CustomStringConvertible, Sendable {
        case missingSystemRoot(String)
        case pathOutsideSystemLibrary(path: String, systemLibraryRoot: String)
        case enumerationFailed(path: String, message: String)

        var description: String {
            switch self {
            case .missingSystemRoot(let path):
                "system root does not exist or is not a directory: \(path)"
            case .pathOutsideSystemLibrary(let path, let systemLibraryRoot):
                "target path is outside System/Library: \(path) is not under \(systemLibraryRoot)"
            case .enumerationFailed(let path, let message):
                "could not enumerate \(path): \(message)"
            }
        }
    }
}

private struct SharedCacheImageIndex {
    private let exactPaths: Set<String>

    init(paths: [String]) {
        self.exactPaths = Set(paths.compactMap(Self.normalizedAbsolutePath))
    }

    func containsAny(_ candidates: [String]) -> Bool {
        candidates.contains { exactPaths.contains($0) }
    }

    private static func normalizedAbsolutePath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }
}

private extension PrivateHeaderGeneration.TargetDiscovery {
    static func discoverFrameworks(
        in systemRoot: URL,
        location: FrameworkLocation,
        includeNestedChildren: Bool,
        sharedCacheImages: SharedCacheImageIndex,
        fileManager: FileManager
    ) throws -> [DiscoveredTargetGroup] {
        let frameworksDirectory = systemRoot
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(location.systemLibraryDirectoryName, isDirectory: true)
        guard try isDirectory(frameworksDirectory, fileManager: fileManager) else {
            return []
        }

        let bundleNames = try contentsOfDirectoryIfPresent(
            at: frameworksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            fileManager: fileManager
        )
        .filter { entry in
            guard entry.pathExtension.lowercased() == "framework" else { return false }
            return try isDirectory(entry, fileManager: fileManager)
        }
        .map(\.lastPathComponent)
        .sorted()

        return try bundleNames.compactMap { bundleName in
            let source = FrameworkSource(
                location: location,
                bundleName: bundleName
            )
            let sourceMetadata = SourceMetadata.framework(source)
            let bundleURL = frameworksDirectory.appendingPathComponent(bundleName, isDirectory: true)
            let childTargets = try includeNestedChildren ? nestedChildTargets(
                parentSystemLibraryRelativePath: source.systemLibraryRelativePath,
                parentURL: bundleURL,
                systemRoot: systemRoot,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            ) : []
            let selectionCandidate = try PrivateHeaderGeneration.TargetCandidate(
                identifier: "\(location.identifierPrefix):\(bundleName)",
                displayName: source.frameworkName,
                kind: location.targetKind,
                aliases: [
                    bundleName,
                    source.systemLibraryRelativePath,
                    "/System/Library/\(source.systemLibraryRelativePath)",
                ]
            )
            let primaryTarget = try loadableBundleTarget(
                candidate: selectionCandidate,
                source: sourceMetadata,
                bundleURL: bundleURL,
                systemRoot: systemRoot,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            )
            guard primaryTarget != nil || !childTargets.isEmpty else { return nil }
            return DiscoveredTargetGroup(
                selectionCandidate: selectionCandidate,
                primaryTarget: primaryTarget,
                childTargets: childTargets
            )
        }
    }

    static func discoverSystemLibraryBundles(
        in systemRoot: URL,
        includeNestedChildren: Bool,
        sharedCacheImages: SharedCacheImageIndex,
        fileManager: FileManager
    ) throws -> [DiscoveredTargetGroup] {
        let systemLibraryDirectory = systemRoot
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        guard try isDirectory(systemLibraryDirectory, fileManager: fileManager) else {
            return []
        }
        let systemLibraryPath = systemLibraryDirectory.standardizedFileURL.path

        let excludedDirectories: Set<String> = [
            systemLibraryDirectory.appendingPathComponent("Frameworks", isDirectory: true).standardizedFileURL.path,
            systemLibraryDirectory.appendingPathComponent("PrivateFrameworks", isDirectory: true).standardizedFileURL.path,
        ]

        var enumerationFailure: (URL, any Swift.Error)?
        guard let enumerator = fileManager.enumerator(
            at: systemLibraryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                if url.standardizedFileURL.path != systemLibraryPath,
                   isPermissionDeniedError(error)
                {
                    return true
                }
                enumerationFailure = (url, error)
                return false
            }
        ) else {
            throw Error.enumerationFailed(
                path: systemLibraryDirectory.path,
                message: "FileManager returned no enumerator"
            )
        }

        var groups: [DiscoveredTargetGroup] = []
        while let url = enumerator.nextObject() as? URL {
            let standardizedPath = url.standardizedFileURL.path
            if excludedDirectories.contains(standardizedPath) {
                enumerator.skipDescendants()
                continue
            }

            do {
                guard try isDirectory(url, fileManager: fileManager) else {
                    continue
                }
            } catch where isPermissionDeniedError(error) {
                continue
            }
            guard let bundleKind = BundleKind(pathExtension: url.pathExtension) else {
                continue
            }

            let relativePath = try systemLibraryRelativePath(
                for: url,
                systemLibraryDirectory: systemLibraryDirectory
            )
            let source = SystemLibraryBundleSource(
                relativePath: relativePath,
                bundleKind: bundleKind,
                role: .topLevel
            )
            if let group = try systemLibraryBundleGroup(
                source: source,
                bundleURL: url,
                systemRoot: systemRoot,
                includeNestedChildren: includeNestedChildren,
                sharedCacheImages: sharedCacheImages,
                fileManager: fileManager
            ) {
                groups.append(group)
            }
            enumerator.skipDescendants()
        }
        if let (url, error) = enumerationFailure {
            throw Error.enumerationFailed(path: url.path, message: String(describing: error))
        }

        return groups.sorted {
            $0.selectionCandidate.identifier < $1.selectionCandidate.identifier
        }
    }

    static func discoverUsrLibDylibs(
        in systemRoot: URL,
        sharedCacheImagePaths: [String],
        fileManager: FileManager
    ) throws -> [DiscoveredTargetGroup] {
        let usrLibDirectory = systemRoot
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
        var filesystemDylibNames: [String] = []
        if try isDirectory(usrLibDirectory, fileManager: fileManager) {
            let dylibEntries = try contentsOfDirectoryIfPresent(
                at: usrLibDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                fileManager: fileManager
            )
            for entry in dylibEntries {
                guard entry.pathExtension.lowercased() == "dylib" else {
                    continue
                }
                let attributes = try fileManager.attributesOfItem(atPath: entry.path)
                let type = attributes[.type] as? FileAttributeType
                if type == .typeRegular || type == .typeSymbolicLink {
                    filesystemDylibNames.append(entry.lastPathComponent)
                }
            }
        }
        let cacheDylibNames = sharedCacheImagePaths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path, isDirectory: false)
            guard
                url.deletingLastPathComponent().path == "/usr/lib",
                url.pathExtension.lowercased() == "dylib"
            else {
                return nil
            }
            return url.lastPathComponent
        }
        let filesystemDylibNameSet = Set(filesystemDylibNames)
        let dylibNames = Set(filesystemDylibNames + cacheDylibNames).sorted()

        return try dylibNames.map { name in
            let source = UsrLibDylibSource(name: name)
            let sourceMetadata = SourceMetadata.usrLibDylib(source)
            let inputPath = filesystemDylibNameSet.contains(name)
                ? hostInputPath(for: sourceMetadata, in: systemRoot)
                : sourceMetadata.runtimeInputPath
            let candidate = try PrivateHeaderGeneration.TargetCandidate(
                identifier: "usr-lib:\(name)",
                displayName: name,
                kind: .usrLibDylib,
                aliases: [
                    "usr/lib/\(name)",
                ]
            )
            let target = DiscoveredTarget(
                candidate: candidate,
                source: sourceMetadata,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("usr/lib/\(name)"),
                inputPath: inputPath,
                runtimeInputPath: sourceMetadata.runtimeInputPath
            )
            return DiscoveredTargetGroup(
                selectionCandidate: candidate,
                primaryTarget: target,
                childTargets: []
            )
        }
    }

    static func nestedChildTargets(
        parentSystemLibraryRelativePath: String,
        parentURL: URL,
        systemRoot: URL,
        sharedCacheImages: SharedCacheImageIndex,
        fileManager: FileManager
    ) throws -> [DiscoveredTarget] {
        guard try isDirectory(parentURL, fileManager: fileManager) else {
            return []
        }

        var targets: [DiscoveredTarget] = []
        for container in nestedBundleContainers {
            let containerURL = parentURL.appendingPathComponent(container.directoryName, isDirectory: true)
            guard try isDirectory(containerURL, fileManager: fileManager) else {
                continue
            }

            let entries = try contentsOfDirectoryIfPresent(
                at: containerURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                fileManager: fileManager
            )
            .filter { entry in
                guard entry.pathExtension.lowercased() == container.bundleKind.rawValue else {
                    return false
                }
                return try isDirectory(entry, fileManager: fileManager)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for entry in entries {
                let childRelativePath = [
                    parentSystemLibraryRelativePath,
                    container.directoryName,
                    entry.lastPathComponent,
                ].joined(separator: "/")
                let source = SystemLibraryBundleSource(
                    relativePath: childRelativePath,
                    bundleKind: container.bundleKind,
                    role: .nestedChild(parentRelativePath: parentSystemLibraryRelativePath)
                )
                let candidate = try systemLibraryCandidate(for: source)
                if let target = try loadableBundleTarget(
                    candidate: candidate,
                    source: .systemLibraryBundle(source),
                    bundleURL: entry,
                    systemRoot: systemRoot,
                    sharedCacheImages: sharedCacheImages,
                    fileManager: fileManager
                ) {
                    targets.append(target)
                }
            }
        }

        return targets.sorted { $0.source.runtimeInputPath < $1.source.runtimeInputPath }
    }

    static func systemLibraryBundleGroup(
        source: SystemLibraryBundleSource,
        bundleURL: URL,
        systemRoot: URL,
        includeNestedChildren: Bool,
        sharedCacheImages: SharedCacheImageIndex,
        fileManager: FileManager
    ) throws -> DiscoveredTargetGroup? {
        let childTargets = try includeNestedChildren ? nestedChildTargets(
            parentSystemLibraryRelativePath: source.relativePath,
            parentURL: bundleURL,
            systemRoot: systemRoot,
            sharedCacheImages: sharedCacheImages,
            fileManager: fileManager
        ) : []
        let sourceMetadata = SourceMetadata.systemLibraryBundle(source)
        let selectionCandidate = try systemLibraryCandidate(for: source)
        let primaryTarget = try loadableBundleTarget(
            candidate: selectionCandidate,
            source: sourceMetadata,
            bundleURL: bundleURL,
            systemRoot: systemRoot,
            sharedCacheImages: sharedCacheImages,
            fileManager: fileManager
        )
        guard primaryTarget != nil || !childTargets.isEmpty else { return nil }
        return DiscoveredTargetGroup(
            selectionCandidate: selectionCandidate,
            primaryTarget: primaryTarget,
            childTargets: childTargets
        )
    }

    static func systemLibraryCandidate(
        for source: SystemLibraryBundleSource
    ) throws -> PrivateHeaderGeneration.TargetCandidate {
        let kind: PrivateHeaderGeneration.TargetKind = switch source.role {
        case .topLevel: .systemBundle
        case .nestedChild: .nestedBundle
        }
        return try PrivateHeaderGeneration.TargetCandidate(
            identifier: systemLibraryIdentifier(for: source),
            displayName: source.relativePath,
            kind: kind,
            aliases: [
                "/System/Library/\(source.relativePath)",
            ]
        )
    }

    static func loadableBundleTarget(
        candidate: PrivateHeaderGeneration.TargetCandidate,
        source: SourceMetadata,
        bundleURL: URL,
        systemRoot: URL,
        sharedCacheImages: SharedCacheImageIndex,
        fileManager: FileManager
    ) throws -> DiscoveredTarget? {
        guard
            let executableURL = selectedBundleExecutableURL(
                bundleURL: bundleURL,
                fileManager: fileManager
            ),
            safeExecutableName(executableURL.lastPathComponent) != nil
        else {
            return nil
        }
        let hasDiskExecutable = try isRegularFileOrSymlinkToRegularFile(
            executableURL,
            fileManager: fileManager
        )
        let hasSharedCacheExecutable = sharedCacheImages.containsAny(
            ExecutableResolution.normalizedCacheImagePaths(
                for: executableURL.path,
                environment: ["PH_RUNTIME_ROOT": systemRoot.path]
            )
        )
        guard hasDiskExecutable || hasSharedCacheExecutable else {
            return nil
        }
        guard let systemLibraryRelativePath = bundleSystemLibraryRelativePath(for: source) else {
            return nil
        }
        return DiscoveredTarget(
            candidate: candidate,
            source: source,
            artifactRoot: try artifactRoot(systemLibraryRelativePath: systemLibraryRelativePath),
            inputPath: hostInputPath(for: source, in: systemRoot),
            runtimeInputPath: source.runtimeInputPath
        )
    }

    static func bundleSystemLibraryRelativePath(for source: SourceMetadata) -> String? {
        switch source {
        case .framework(let framework): framework.systemLibraryRelativePath
        case .systemLibraryBundle(let bundle): bundle.relativePath
        case .usrLibDylib: nil
        }
    }

    static func selectedBundleExecutableURL(
        bundleURL: URL,
        fileManager: FileManager
    ) -> URL? {
        ExecutableResolution.resolveBundleExecutableURL(
            bundleURL,
            fileExists: fileManager.fileExists(atPath:)
        )
    }

    static func isRegularFileOrSymlinkToRegularFile(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch where isMissingFileError(error) {
            return false
        }
        let type = attributes[.type] as? FileAttributeType
        if type == .typeRegular {
            return true
        }
        guard type == .typeSymbolicLink else {
            return false
        }
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        do {
            let resolvedAttributes = try fileManager.attributesOfItem(atPath: resolvedURL.path)
            return resolvedAttributes[.type] as? FileAttributeType == .typeRegular
        } catch where isMissingFileError(error) {
            return false
        }
    }

    static var nestedBundleContainers: [(directoryName: String, bundleKind: BundleKind)] {
        [
            ("XPCServices", .xpc),
            ("PlugIns", .appex),
        ]
    }

    static func systemLibraryIdentifier(for source: SystemLibraryBundleSource) -> String {
        switch source.role {
        case .topLevel:
            "system-library:\(source.relativePath)"
        case .nestedChild:
            "nested-bundle:\(source.relativePath)"
        }
    }

    static func systemLibraryRelativePath(
        for url: URL,
        systemLibraryDirectory: URL
    ) throws -> String {
        let rootPath = systemLibraryDirectory.standardizedFileURL.path
        let basePath = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else {
            throw Error.pathOutsideSystemLibrary(
                path: path,
                systemLibraryRoot: rootPath
            )
        }
        return String(path.dropFirst(basePath.count))
    }

    static func artifactRoot(
        systemLibraryRelativePath: String
    ) throws -> PrivateHeaderGeneration.ArtifactPath {
        let sourceComponents = systemLibraryRelativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)

        let artifactComponents: [String]
        switch sourceComponents.first {
        case "Frameworks", "PrivateFrameworks":
            artifactComponents = frameworkArtifactComponents(sourceComponents)
        default:
            artifactComponents = ["SystemLibrary"] + sourceComponents
        }

        return try PrivateHeaderGeneration.ArtifactPath(
            artifactComponents.joined(separator: "/")
        )
    }

    static func hostInputPath(for source: SourceMetadata, in systemRoot: URL) -> String {
        let relativePath = String(source.runtimeInputPath.dropFirst())
        return systemRoot.appendingPathComponent(relativePath, isDirectory: false).path
    }

    static func frameworkArtifactComponents(_ sourceComponents: [String]) -> [String] {
        guard sourceComponents.count > 1 else {
            return sourceComponents
        }
        var artifactComponents = sourceComponents
        artifactComponents[1] = artifactComponents[1]
            .removingCaseInsensitiveSuffix(".framework")
        return artifactComponents
    }

    static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            guard type == .typeSymbolicLink else {
                return type == .typeDirectory
            }

            var status = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                fstatat(AT_FDCWD, path, &status, 0)
            }
            guard result == 0 else {
                let errorCode = errno
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorCode),
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
            return status.st_mode & S_IFMT == S_IFDIR
        } catch where isMissingFileError(error) {
            return false
        }
    }

    static func contentsOfDirectoryIfPresent(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey],
        options: FileManager.DirectoryEnumerationOptions,
        fileManager: FileManager
    ) throws -> [URL] {
        do {
            return try fileManager.contentsOfDirectory(
                at: url.resolvingSymlinksInPath(),
                includingPropertiesForKeys: keys,
                options: options
            )
        } catch where isMissingFileError(error) {
            return []
        }
    }

    static func isMissingFileError(_ error: any Swift.Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
        {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingFileError(underlying)
        }
        return false
    }

    static func isPermissionDeniedError(_ error: any Swift.Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM)
        {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDeniedError(underlying)
        }
        return false
    }
}

private func safeExecutableName(_ value: String) -> String? {
    guard
        !value.isEmpty,
        value != ".",
        value != "..",
        !value.contains("/"),
        !value.contains("\0")
    else {
        return nil
    }
    return value
}

private extension String {
    func removingCaseInsensitiveSuffix(_ suffix: String) -> String {
        guard lowercased().hasSuffix(suffix.lowercased()) else {
            return self
        }
        return String(dropLast(suffix.count))
    }
}
