import Foundation
import MachOKit
import ObjCDump

#if canImport(ObjectiveC)
import ObjectiveC
import PrivateHeaderKitRawDumpRuntimeObjC

private func runtimePropertyInfo(
    from snapshot: PHRuntimeObjCPropertySnapshot
) -> ObjCPropertyInfo {
    ObjCPropertyInfo(
        name: snapshot.name,
        attributesString: snapshot.attributesString,
        isClassProperty: snapshot.isClassProperty
    )
}

private func runtimeMethodInfo(
    from snapshot: PHRuntimeObjCMethodSnapshot
) -> ObjCMethodInfo {
    ObjCMethodInfo(
        name: snapshot.name,
        typeEncoding: snapshot.typeEncoding,
        isClassMethod: snapshot.isClassMethod,
        imp: 0
    )
}

private func runtimeIvarInfo(
    from snapshot: PHRuntimeObjCIvarSnapshot
) -> ObjCIvarInfo {
    ObjCIvarInfo(
        name: snapshot.name,
        typeEncoding: snapshot.typeEncoding,
        offset: Int(snapshot.offset)
    )
}

private func runtimeProtocolInfo(
    from snapshot: PHRuntimeObjCProtocolSnapshot
) -> ObjCProtocolInfo {
    ObjCProtocolInfo(
        name: snapshot.name,
        protocols: snapshot.protocols.map(runtimeProtocolInfo(from:)),
        classProperties: snapshot.classProperties.map(runtimePropertyInfo(from:)),
        properties: snapshot.properties.map(runtimePropertyInfo(from:)),
        classMethods: snapshot.classMethods.map(runtimeMethodInfo(from:)),
        methods: snapshot.methods.map(runtimeMethodInfo(from:)),
        optionalClassProperties: snapshot.optionalClassProperties.map(runtimePropertyInfo(from:)),
        optionalProperties: snapshot.optionalProperties.map(runtimePropertyInfo(from:)),
        optionalClassMethods: snapshot.optionalClassMethods.map(runtimeMethodInfo(from:)),
        optionalMethods: snapshot.optionalMethods.map(runtimeMethodInfo(from:))
    )
}

@MainActor
private func runtimeClassInfo(
    for cls: AnyClass,
    runtimeOriginName: String,
    imagePath: String,
    verbose: Bool
) -> ObjCClassInfo? {
    var failedStage: NSString?
    guard let snapshot = PHRuntimeObjCInspector.snapshot(for: cls, failedStage: &failedStage) else {
        if verbose {
            let stage = (failedStage as String?) ?? "unknown"
            fputs(
                "privateheaderkit __raw-dump: runtime fallback skip class \(runtimeOriginName) image=\(imagePath) stage=\(stage)\n",
                stderr
            )
        }
        return nil
    }

    // The caller-provided runtime-origin spelling owns identity. The primary path
    // uses `objc_copyClassNamesForImage`; its `class_getName` fallback may instead
    // provide a qualified `Module.Type` name on current runtimes.
    return ObjCClassInfo(
        name: runtimeOriginName,
        version: snapshot.version,
        imageName: snapshot.imageName,
        instanceSize: Int(snapshot.instanceSize),
        superClassName: snapshot.superclassObjCRuntimeName,
        protocols: snapshot.protocols.map(runtimeProtocolInfo(from:)),
        ivars: snapshot.ivars.map(runtimeIvarInfo(from:)),
        classProperties: snapshot.classProperties.map(runtimePropertyInfo(from:)),
        properties: snapshot.properties.map(runtimePropertyInfo(from:)),
        classMethods: snapshot.classMethods.map(runtimeMethodInfo(from:)),
        methods: snapshot.methods.map(runtimeMethodInfo(from:))
    )
}

@MainActor
func withLoadedRuntimeImage<Result: Sendable>(
    at path: String,
    open: @MainActor @Sendable (String) -> UnsafeMutableRawPointer? = {
        dlopen($0, RTLD_LAZY)
    },
    close: @MainActor @Sendable (UnsafeMutableRawPointer) -> Void = {
        _ = dlclose($0)
    },
    inspect: @MainActor @Sendable (UnsafeMutableRawPointer) throws -> Result
) rethrows -> Result? {
    guard let handle = open(path) else { return nil }
    defer { close(handle) }
    return try inspect(handle)
}

struct ObjectiveCRuntimeImageIdentity: Equatable, Sendable {
    let path: String

    fileprivate init(path: String) {
        self.path = path
    }
}

func matchingLoadedRuntimeImageIdentity(
    for targetImagePath: String,
    loadedImageNames: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> ObjectiveCRuntimeImageIdentity? {
    let runtimeRoots = runtimeImageIdentityRoots(environment: environment)
    let targetCandidates = Set(
        normalizedCacheImagePaths(
            for: targetImagePath,
            environment: environment
        )
    )
    var matchedName: String?
    var visitedNames: Set<String> = []

    for loadedImageName in loadedImageNames where visitedNames.insert(loadedImageName).inserted {
        let matchesTarget = targetCandidates.contains(loadedImageName)
            || runtimeRoots.contains { runtimeRoot in
                guard let logicalPath = pathRemovingRuntimeRoot(
                    loadedImageName,
                    runtimeRoot: runtimeRoot
                ) else {
                    return false
                }
                return targetCandidates.contains(logicalPath)
            }
        guard matchesTarget else {
            continue
        }
        guard matchedName == nil else {
            return nil
        }
        matchedName = loadedImageName
    }

    return matchedName.map(ObjectiveCRuntimeImageIdentity.init(path:))
}

func runtimeRootedImageIdentity(
    loadPath: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileExistenceChecking = FileManager.default
) -> ObjectiveCRuntimeImageIdentity? {
    guard fileManager.fileExists(atPath: loadPath) else { return nil }
    if let runtimeRoot = runtimeRootPath(environment: environment),
       URL(fileURLWithPath: runtimeRoot, isDirectory: true).standardizedFileURL.path == "/"
    {
        return ObjectiveCRuntimeImageIdentity(path: loadPath)
    }
    let runtimeRoots = runtimeImageIdentityRoots(environment: environment)
    guard runtimeRoots.contains(where: { runtimeRoot in
        pathRemovingRuntimeRoot(loadPath, runtimeRoot: runtimeRoot) != nil
    }) else {
        return nil
    }
    return ObjectiveCRuntimeImageIdentity(path: loadPath)
}

private func runtimeImageIdentityRoots(environment: [String: String]) -> [String] {
    guard let runtimeRoot = runtimeRootPath(environment: environment) else {
        return []
    }
    let lexicalRoot = URL(fileURLWithPath: runtimeRoot, isDirectory: true)
        .standardizedFileURL
        .path
    let resolvedRoot = URL(fileURLWithPath: runtimeRoot, isDirectory: true)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
    var roots = lexicalRoot == "/" ? [] : [lexicalRoot]
    if resolvedRoot != "/", resolvedRoot != lexicalRoot {
        roots.append(resolvedRoot)
    }
    return roots
}

private func pathRemovingRuntimeRoot(_ path: String, runtimeRoot: String) -> String? {
    guard runtimeRoot != "/" else { return nil }
    let rootPrefix = runtimeRoot + "/"
    guard path.hasPrefix(rootPrefix) else { return nil }
    return "/" + path.dropFirst(rootPrefix.count)
}

@MainActor
private func loadedRuntimeImageNames() -> [String] {
    var count: UInt32 = 0
    let names = objc_copyImageNames(&count)
    defer { free(names) }
    return UnsafeBufferPointer(start: names, count: Int(count)).map {
        String(cString: $0)
    }
}

@MainActor
private func copyRuntimeClassNames(
    for identity: ObjectiveCRuntimeImageIdentity
) -> [String]? {
    var count: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(identity.path, &count) else {
        return nil
    }
    defer { free(names) }
    return UnsafeBufferPointer(start: names, count: Int(count)).map {
        String(cString: $0)
    }
}

@MainActor
func runtimeClassInfos(
    for imagePath: String,
    onlyOneClass: String?,
    verbose: Bool
) -> [ObjCClassInfo] {
    let targetPaths = runtimeFallbackTargetImagePaths(for: imagePath)
    let loadPath = resolveRuntimeURL(URL(fileURLWithPath: imagePath)).path
    guard let infos = withLoadedRuntimeImage(
        at: loadPath,
        inspect: { _ in
            // Cache-only Simulator images can have no file at their registered runtime path.
            var runtimeImageIdentity: ObjectiveCRuntimeImageIdentity?
            var names: [String]?
            if let rootedIdentity = runtimeRootedImageIdentity(loadPath: loadPath),
               let rootedNames = copyRuntimeClassNames(for: rootedIdentity)
            {
                runtimeImageIdentity = rootedIdentity
                names = rootedNames
            }

            if names == nil,
               let inventoryIdentity = matchingLoadedRuntimeImageIdentity(
                   for: imagePath,
                   loadedImageNames: loadedRuntimeImageNames()
               ),
               let inventoryNames = copyRuntimeClassNames(for: inventoryIdentity)
            {
                runtimeImageIdentity = inventoryIdentity
                names = inventoryNames
            }

            guard let runtimeImageIdentity, let names else {
                if verbose {
                    fputs(
                        "privateheaderkit __raw-dump: runtime fallback could not query loaded image identity for \(imagePath)\n",
                        stderr
                    )
                }
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }
            if names.isEmpty {
                if verbose {
                    fputs(
                        "privateheaderkit __raw-dump: runtime fallback objc_copyClassNamesForImage returned 0 classes for \(runtimeImageIdentity.path)\n",
                        stderr
                    )
                }
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }

            var infos: [ObjCClassInfo] = []
            infos.reserveCapacity(names.count)

            for name in names {
                if let onlyOneClass, onlyOneClass != name { continue }
                if let cls = NSClassFromString(name) ?? (objc_getClass(name) as? AnyClass) {
                    if let info = runtimeClassInfo(
                        for: cls,
                        runtimeOriginName: name,
                        imagePath: imagePath,
                        verbose: verbose
                    ) {
                        infos.append(info)
                    }
                }
            }
            if infos.isEmpty {
                return runtimeClassInfosByImageName(
                    targetPaths: targetPaths,
                    imagePath: imagePath,
                    onlyOneClass: onlyOneClass,
                    verbose: verbose
                )
            }
            return infos
        }
    ) else {
        if verbose {
            fputs("privateheaderkit __raw-dump: runtime dlopen failed for \(loadPath)\n", stderr)
        }
        return []
    }
    return infos
}

@MainActor
private func runtimeClassInfosByImageName(
    targetPaths: Set<String>,
    imagePath: String,
    onlyOneClass: String?,
    verbose: Bool
) -> [ObjCClassInfo] {
    let initialCount = objc_getClassList(nil, 0)
    if initialCount <= 0 { return [] }

    let buffer = UnsafeMutablePointer<AnyClass?>.allocate(capacity: Int(initialCount))
    defer { buffer.deallocate() }

    let count = objc_getClassList(AutoreleasingUnsafeMutablePointer(buffer), initialCount)
    if count <= 0 { return [] }
    let cappedCount = min(count, initialCount)

    var infos: [ObjCClassInfo] = []
    infos.reserveCapacity(Int(cappedCount))

    for index in 0..<Int(cappedCount) {
        guard let cls = buffer[index] else { continue }
        guard let imageNamePtr = class_getImageName(cls) else { continue }
        let imageName = String(cString: imageNamePtr)
        let normalizedImage = normalizedImagePath(stripRuntimeRoot(from: imageName))
        if !targetPaths.contains(normalizedImage) { continue }

        let name = String(cString: class_getName(cls))
        if let onlyOneClass, onlyOneClass != name { continue }
        if let info = runtimeClassInfo(
            for: cls,
            runtimeOriginName: name,
            imagePath: imagePath,
            verbose: verbose
        ) {
            infos.append(info)
        }
    }

    if verbose, !infos.isEmpty {
        fputs(
            "privateheaderkit __raw-dump: runtime fallback class_getImageName matched \(infos.count) classes for \(imagePath)\n",
            stderr
        )
    }
    return infos
}

func runtimeFallbackTargetImagePaths(
    for imagePath: String,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Set<String> {
    Set(
        normalizedCacheImagePaths(for: imagePath, environment: environment).map {
            normalizedImagePath(stripRuntimeRoot(from: $0, environment: environment))
        }
    )
}

private func normalizedImagePath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}
#endif
