import Foundation

extension PrivateHeaderGeneration {
    enum TargetDiscovery {
        static func discover(
            in systemRoot: URL,
            includeNestedChildren: Bool = true,
            fileManager: FileManager = .default
        ) throws -> Catalog {
            let root = systemRoot.standardizedFileURL
            guard isDirectory(root, fileManager: fileManager) else {
                throw Error.missingSystemRoot(root.path)
            }

            var targets: [DiscoveredTarget] = []
            targets += try discoverFrameworks(
                in: root,
                location: .publicFramework,
                includeNestedChildren: includeNestedChildren,
                fileManager: fileManager
            )
            targets += try discoverFrameworks(
                in: root,
                location: .privateFramework,
                includeNestedChildren: includeNestedChildren,
                fileManager: fileManager
            )
            targets += try discoverSystemLibraryBundles(
                in: root,
                includeNestedChildren: includeNestedChildren,
                fileManager: fileManager
            )
            targets += try discoverUsrLibDylibs(
                in: root,
                fileManager: fileManager
            )

            return Catalog(targets: targets)
        }
    }
}

extension PrivateHeaderGeneration.TargetDiscovery {
    struct Catalog: Hashable, Sendable {
        let targets: [DiscoveredTarget]

        var resolverCandidates: [PrivateHeaderGeneration.TargetCandidate] {
            targets.map(\.candidate)
        }

        var resolver: PrivateHeaderGeneration.TargetResolver {
            PrivateHeaderGeneration.TargetResolver(candidates: resolverCandidates)
        }

        var allTargetsIncludingNestedChildren: [DiscoveredTarget] {
            targets.flatMap { target in
                [target] + target.childTargets
            }
        }
    }

    struct DiscoveredTarget: Hashable, Sendable {
        let candidate: PrivateHeaderGeneration.TargetCandidate
        let source: SourceMetadata
        let artifactRoot: PrivateHeaderGeneration.ArtifactPath
        let inputPath: String
        let runtimeInputPath: String
        let childTargets: [DiscoveredTarget]
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

        var description: String {
            switch self {
            case .missingSystemRoot(let path):
                "system root does not exist or is not a directory: \(path)"
            case .pathOutsideSystemLibrary(let path, let systemLibraryRoot):
                "target path is outside System/Library: \(path) is not under \(systemLibraryRoot)"
            }
        }
    }
}

private extension PrivateHeaderGeneration.TargetDiscovery {
    static func discoverFrameworks(
        in systemRoot: URL,
        location: FrameworkLocation,
        includeNestedChildren: Bool,
        fileManager: FileManager
    ) throws -> [DiscoveredTarget] {
        let frameworksDirectory = systemRoot
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(location.systemLibraryDirectoryName, isDirectory: true)
        guard isDirectory(frameworksDirectory, fileManager: fileManager) else {
            return []
        }

        let bundleNames = try fileManager.contentsOfDirectory(
            at: frameworksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { entry in
            entry.pathExtension.lowercased() == "framework"
                && isDirectory(entry, fileManager: fileManager)
        }
        .map(\.lastPathComponent)
        .sorted()

        return try bundleNames.map { bundleName in
            let source = FrameworkSource(
                location: location,
                bundleName: bundleName
            )
            let sourceMetadata = SourceMetadata.framework(source)
            let artifactRoot = try artifactRoot(
                systemLibraryRelativePath: source.systemLibraryRelativePath
            )
            let childTargets = try includeNestedChildren ? nestedChildTargets(
                parentSystemLibraryRelativePath: source.systemLibraryRelativePath,
                parentURL: frameworksDirectory.appendingPathComponent(bundleName, isDirectory: true),
                systemRoot: systemRoot,
                fileManager: fileManager
            ) : []

            return DiscoveredTarget(
                candidate: try PrivateHeaderGeneration.TargetCandidate(
                    identifier: "\(location.identifierPrefix):\(bundleName)",
                    displayName: source.frameworkName,
                    kind: location.targetKind,
                    aliases: [
                        bundleName,
                        source.systemLibraryRelativePath,
                        "/System/Library/\(source.systemLibraryRelativePath)",
                    ]
                ),
                source: sourceMetadata,
                artifactRoot: artifactRoot,
                inputPath: hostInputPath(for: sourceMetadata, in: systemRoot),
                runtimeInputPath: sourceMetadata.runtimeInputPath,
                childTargets: childTargets
            )
        }
    }

    static func discoverSystemLibraryBundles(
        in systemRoot: URL,
        includeNestedChildren: Bool,
        fileManager: FileManager
    ) throws -> [DiscoveredTarget] {
        let systemLibraryDirectory = systemRoot
            .appendingPathComponent("System", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        guard isDirectory(systemLibraryDirectory, fileManager: fileManager) else {
            return []
        }

        let excludedDirectories: Set<String> = [
            systemLibraryDirectory.appendingPathComponent("Frameworks", isDirectory: true).standardizedFileURL.path,
            systemLibraryDirectory.appendingPathComponent("PrivateFrameworks", isDirectory: true).standardizedFileURL.path,
        ]

        guard let enumerator = fileManager.enumerator(
            at: systemLibraryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var targets: [DiscoveredTarget] = []
        while let url = enumerator.nextObject() as? URL {
            let standardizedPath = url.standardizedFileURL.path
            if excludedDirectories.contains(standardizedPath) {
                enumerator.skipDescendants()
                continue
            }

            guard isDirectory(url, fileManager: fileManager) else {
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
            targets.append(
                try systemLibraryBundleTarget(
                    source: source,
                    bundleURL: url,
                    systemRoot: systemRoot,
                    includeNestedChildren: includeNestedChildren,
                    fileManager: fileManager
                )
            )
            enumerator.skipDescendants()
        }

        return targets.sorted { $0.source.runtimeInputPath < $1.source.runtimeInputPath }
    }

    static func discoverUsrLibDylibs(
        in systemRoot: URL,
        fileManager: FileManager
    ) throws -> [DiscoveredTarget] {
        let usrLibDirectory = systemRoot
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
        guard isDirectory(usrLibDirectory, fileManager: fileManager) else {
            return []
        }

        let dylibNames = try fileManager.contentsOfDirectory(
            at: usrLibDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { entry in
            guard entry.pathExtension.lowercased() == "dylib" else {
                return false
            }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true || values?.isSymbolicLink == true
        }
        .map(\.lastPathComponent)
        .sorted()

        return try dylibNames.map { name in
            let source = UsrLibDylibSource(name: name)
            let sourceMetadata = SourceMetadata.usrLibDylib(source)
            return DiscoveredTarget(
                candidate: try PrivateHeaderGeneration.TargetCandidate(
                    identifier: "usr-lib:\(name)",
                    displayName: name,
                    kind: .usrLibDylib,
                    aliases: [
                        "usr/lib/\(name)",
                    ]
                ),
                source: sourceMetadata,
                artifactRoot: try PrivateHeaderGeneration.ArtifactPath("usr/lib/\(name)"),
                inputPath: hostInputPath(for: sourceMetadata, in: systemRoot),
                runtimeInputPath: sourceMetadata.runtimeInputPath,
                childTargets: []
            )
        }
    }

    static func nestedChildTargets(
        parentSystemLibraryRelativePath: String,
        parentURL: URL,
        systemRoot: URL,
        fileManager: FileManager
    ) throws -> [DiscoveredTarget] {
        guard isDirectory(parentURL, fileManager: fileManager) else {
            return []
        }

        var targets: [DiscoveredTarget] = []
        for container in nestedBundleContainers {
            let containerURL = parentURL.appendingPathComponent(container.directoryName, isDirectory: true)
            guard isDirectory(containerURL, fileManager: fileManager) else {
                continue
            }

            let entries = try fileManager.contentsOfDirectory(
                at: containerURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { entry in
                entry.pathExtension.lowercased() == container.bundleKind.rawValue
                    && isDirectory(entry, fileManager: fileManager)
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
                targets.append(
                    try systemLibraryBundleTarget(
                        source: source,
                        bundleURL: entry,
                        systemRoot: systemRoot,
                        includeNestedChildren: false,
                        fileManager: fileManager
                    )
                )
            }
        }

        return targets.sorted { $0.source.runtimeInputPath < $1.source.runtimeInputPath }
    }

    static func systemLibraryBundleTarget(
        source: SystemLibraryBundleSource,
        bundleURL: URL,
        systemRoot: URL,
        includeNestedChildren: Bool,
        fileManager: FileManager
    ) throws -> DiscoveredTarget {
        let kind: PrivateHeaderGeneration.TargetKind
        switch source.role {
        case .topLevel:
            kind = .systemBundle
        case .nestedChild:
            kind = .nestedBundle
        }

        let childTargets = try includeNestedChildren ? nestedChildTargets(
            parentSystemLibraryRelativePath: source.relativePath,
            parentURL: bundleURL,
            systemRoot: systemRoot,
            fileManager: fileManager
        ) : []
        let sourceMetadata = SourceMetadata.systemLibraryBundle(source)

        return DiscoveredTarget(
            candidate: try PrivateHeaderGeneration.TargetCandidate(
                identifier: systemLibraryIdentifier(for: source),
                displayName: source.relativePath,
                kind: kind,
                aliases: [
                    "/System/Library/\(source.relativePath)",
                ]
            ),
            source: sourceMetadata,
            artifactRoot: try artifactRoot(systemLibraryRelativePath: source.relativePath),
            inputPath: hostInputPath(for: sourceMetadata, in: systemRoot),
            runtimeInputPath: sourceMetadata.runtimeInputPath,
            childTargets: childTargets
        )
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
        let components = systemLibraryRelativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { normalizeBundleArtifactComponent(String($0)) }

        let artifactComponents: [String]
        switch components.first {
        case "Frameworks", "PrivateFrameworks":
            artifactComponents = components
        default:
            artifactComponents = ["SystemLibrary"] + components
        }

        return try PrivateHeaderGeneration.ArtifactPath(
            artifactComponents.joined(separator: "/")
        )
    }

    static func hostInputPath(for source: SourceMetadata, in systemRoot: URL) -> String {
        let relativePath = String(source.runtimeInputPath.dropFirst())
        return systemRoot.appendingPathComponent(relativePath, isDirectory: false).path
    }

    static func normalizeBundleArtifactComponent(_ component: String) -> String {
        for suffix in artifactStrippedBundleSuffixes where component.lowercased().hasSuffix(suffix) {
            return component.removingCaseInsensitiveSuffix(suffix)
        }
        return component
    }

    static let artifactStrippedBundleSuffixes = [
        ".framework",
        ".app",
        ".bundle",
        ".xpc",
        ".appex",
    ]

    static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

private extension String {
    func removingCaseInsensitiveSuffix(_ suffix: String) -> String {
        guard lowercased().hasSuffix(suffix.lowercased()) else {
            return self
        }
        return String(dropLast(suffix.count))
    }
}
