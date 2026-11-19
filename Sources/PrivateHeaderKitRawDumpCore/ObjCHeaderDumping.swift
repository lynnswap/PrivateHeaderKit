import Foundation
@_spi(Support) import MachOKit
@_spi(Diagnostics) import MachOObjCSection
import ObjCDump
import PrivateHeaderKitHelperProtocol
#if canImport(ObjectiveC)
import ObjectiveC
import PrivateHeaderKitRawDumpRuntimeObjC
#endif

enum ObjCHeaderSymbolKind: String, Comparable {
    case `class` = "class"
    case `protocol` = "protocol"
    case category = "category"

    private var sortOrder: Int {
        switch self {
        case .class:
            return 0
        case .protocol:
            return 1
        case .category:
            return 2
        }
    }

    static func < (lhs: ObjCHeaderSymbolKind, rhs: ObjCHeaderSymbolKind) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct ObjCHeaderEntry: Equatable {
    let symbolKind: ObjCHeaderSymbolKind
    let rawIdentity: String
    let displayBaseName: String
    let headerString: String
}

struct ResolvedObjCHeaderEntry: Equatable {
    let symbolKind: ObjCHeaderSymbolKind
    let rawIdentity: String
    let displayBaseName: String
    let headerString: String
    let fileName: String
    let hadNameCollision: Bool
}

func isSaneObjCTypeName(_ name: String) -> Bool {
    if name.isEmpty { return false }
    for scalar in name.unicodeScalars {
        // U+FFFD is a strong signal we decoded invalid UTF-8 from runtime metadata.
        if scalar.value == 0xFFFD { return false }
        // Control characters (including \t, \n, form feed, etc) make both filenames and headers unreadable.
        if scalar.properties.generalCategory == .control { return false }
    }
    return true
}

private struct PendingObjCHeaderFileName {
    let entry: ObjCHeaderEntry
    let fileName: String
    let collisionKey: String
}

private func caseInsensitiveFileNameKey(_ fileName: String) -> String {
    fileName.folding(options: [.caseInsensitive], locale: caseInsensitiveFileNameLocale)
}

private func collisionSuffix(for entry: ObjCHeaderEntry) -> String {
    "~\(stableHashHex("\(entry.symbolKind.rawValue):\(entry.rawIdentity)"))"
}

func resolveObjCHeaderEntries(_ entries: [ObjCHeaderEntry], options: DumpOptions) -> [ResolvedObjCHeaderEntry] {
    let sortedEntries = entries.sorted { lhs, rhs in
        if lhs.symbolKind != rhs.symbolKind {
            return lhs.symbolKind < rhs.symbolKind
        }
        if lhs.displayBaseName != rhs.displayBaseName {
            return lhs.displayBaseName < rhs.displayBaseName
        }
        if lhs.rawIdentity != rhs.rawIdentity {
            return lhs.rawIdentity < rhs.rawIdentity
        }
        return lhs.headerString < rhs.headerString
    }

    let pending = sortedEntries.map { entry in
        let fileName = safeFileName(baseName: entry.displayBaseName, extension: ".h")
        return PendingObjCHeaderFileName(
            entry: entry,
            fileName: fileName,
            collisionKey: caseInsensitiveFileNameKey(fileName)
        )
    }
    let grouped = Dictionary(grouping: pending, by: \.collisionKey)

    return pending.map { item in
        let hadCollision = (grouped[item.collisionKey]?.count ?? 0) > 1
        let resolvedFileName: String
        if hadCollision {
            resolvedFileName = safeFileName(
                baseName: item.entry.displayBaseName,
                suffix: collisionSuffix(for: item.entry),
                extension: ".h"
            )
            if options.verbose {
                fputs(
                    "privateheaderkit __raw-dump: resolved case-insensitive header name collision \(item.entry.symbolKind.rawValue):\(item.entry.rawIdentity) -> \(resolvedFileName)\n",
                    stderr
                )
            }
        } else {
            resolvedFileName = item.fileName
        }

        return ResolvedObjCHeaderEntry(
            symbolKind: item.entry.symbolKind,
            rawIdentity: item.entry.rawIdentity,
            displayBaseName: item.entry.displayBaseName,
            headerString: item.entry.headerString,
            fileName: resolvedFileName,
            hadNameCollision: hadCollision
        )
    }
}

func dumpObjC(
    machO: RawMachO,
    imagePath: String,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) async throws {
    var metadata: CollectedObjCMetadata
    switch machO {
    case .file(let file):
        let roots = file.objc.readRoots()
        options.objcDiagnostics.append(contentsOf: roots.tableDiagnostics)
        metadata = collectObjCMetadata(from: roots, in: machO, options: options)
    case .loaded(let image):
        let roots = image.objc.readRoots()
        options.objcDiagnostics.append(contentsOf: roots.tableDiagnostics)
        metadata = collectObjCMetadata(from: roots, in: machO, options: options)
    }

#if canImport(ObjectiveC)
    if options.useRuntimeFallback {
        let runtimeInfos = await runtimeClassInfos(
            for: imagePath,
            onlyOneClass: options.onlyOneClass,
            verbose: options.verbose
        )
        metadata.runtimeOriginClassNames = supplementMissingRuntimeClassInfos(
            runtimeInfos,
            into: &metadata.classInfos
        )
        if options.verbose {
            fputs(
                "privateheaderkit __raw-dump: runtime fallback added \(metadata.runtimeOriginClassNames.count) classes for \(imagePath)\n",
                stderr
            )
        }
    }
#endif

    try writeObjCMetadata(
        metadata,
        outputDir: outputDir,
        options: options,
        fileManager: fileManager
    )
}

private struct CollectedObjCMetadata {
    var classInfos: [String: ObjCClassInfo] = [:]
    var protocolInfos: [String: ObjCProtocolInfo] = [:]
    var categoryInfos: [String: ObjCCategoryInfo] = [:]
    var runtimeOriginClassNames: Set<String> = []
}

private protocol RawDumpObjCRoots {
    var classes64: [ObjCClass64]? { get }
    var classes32: [ObjCClass32]? { get }
    var nonLazyClasses64: [ObjCClass64]? { get }
    var nonLazyClasses32: [ObjCClass32]? { get }
    var protocols64: [ObjCProtocol64]? { get }
    var protocols32: [ObjCProtocol32]? { get }
    var categories64: [ObjCCategory64]? { get }
    var categories32: [ObjCCategory32]? { get }
    var nonLazyCategories64: [ObjCCategory64]? { get }
    var nonLazyCategories32: [ObjCCategory32]? { get }
    var categories2_64: [ObjCCategory64]? { get }
    var categories2_32: [ObjCCategory32]? { get }
}

extension ObjCFileRootReadResult: RawDumpObjCRoots {}
extension ObjCImageRootReadResult: RawDumpObjCRoots {}

@discardableResult
func supplementMissingRuntimeClassInfos(
    _ runtimeInfos: [ObjCClassInfo],
    into classInfos: inout [String: ObjCClassInfo]
) -> Set<String> {
    var logicalIdentities = Set(classInfos.values.map {
        logicalClassIdentity(name: $0.name, runtimeOrigin: false)
    })
    var insertedNames: Set<String> = []
    for info in runtimeInfos.sorted(by: { runtimeClassSortKey($0.name) < runtimeClassSortKey($1.name) }) {
        guard classInfos[info.name] == nil else { continue }
        let logicalIdentity = logicalClassIdentity(name: info.name, runtimeOrigin: true)
        guard logicalIdentities.insert(logicalIdentity).inserted else { continue }
        classInfos[info.name] = info
        insertedNames.insert(info.name)
    }
    return insertedNames
}

private func logicalClassIdentity(name: String, runtimeOrigin: Bool) -> String {
    let lookup = runtimeOrigin
        ? SwiftObjCNameResolver.resolveRuntimeOriginClassName(name)
        : SwiftObjCNameResolver.resolve(name)
    if case .resolved(let resolved) = lookup, resolved.kind == .class {
        // Runtime-qualified names have no intrinsic mangling tree. Bridge them to
        // static metadata only through the explicit kind + display projection.
        return "swift-display:class:\(resolved.displayName.utf8.count):\(resolved.displayName)"
    }
    return "objc:\(name)"
}

private func runtimeClassSortKey(_ name: String) -> String {
    let rank: Int
    if case .resolved(let resolved) = SwiftObjCNameResolver.resolve(name),
       resolved.source == .objcRuntimeName {
        rank = 0
    } else if case .resolved = SwiftObjCNameResolver.resolveRuntimeOriginClassName(name) {
        rank = 1
    } else {
        rank = 2
    }
    return "\(rank):\(name)"
}

private func collectObjCMetadata<Roots: RawDumpObjCRoots>(
    from objc: Roots,
    in machO: RawMachO,
    options: DumpOptions
) -> CollectedObjCMetadata {
    var metadata = CollectedObjCMetadata()

    if let list = objc.classes64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.classes32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.nonLazyClasses64 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }
    if let list = objc.nonLazyClasses32 {
        collectClassInfos(list, in: machO, options: options, classInfos: &metadata.classInfos)
    }

    var protocolCandidates: [any ObjCProtocolProtocol] = []
    if let list = objc.protocols64 { protocolCandidates.append(contentsOf: list) }
    if let list = objc.protocols32 { protocolCandidates.append(contentsOf: list) }

    for proto in protocolCandidates {
        if let info = protocolInfo(
            proto,
            in: machO,
            diagnostics: options.objcDiagnostics
        ) {
            metadata.protocolInfos[info.name] = info
        }
    }

    var categoryCandidates: [any ObjCCategoryProtocol] = []
    if let list = objc.categories64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories32 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.nonLazyCategories64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.nonLazyCategories32 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories2_64 { categoryCandidates.append(contentsOf: list) }
    if let list = objc.categories2_32 { categoryCandidates.append(contentsOf: list) }

    for category in categoryCandidates {
        if let info = categoryInfo(
            category,
            in: machO,
            diagnostics: options.objcDiagnostics
        ) {
            let key = "\(info.className)(\(info.name))"
            metadata.categoryInfos[key] = info
        }
    }

    return metadata
}

private func writeObjCMetadata(
    _ metadata: CollectedObjCMetadata,
    outputDir: URL,
    options: DumpOptions,
    fileManager: FileManager
) throws {
    let classInfos = metadata.classInfos
    let protocolInfos = metadata.protocolInfos
    let categoryInfos = metadata.categoryInfos

    try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

    var entries: [ObjCHeaderEntry] = []
    entries.reserveCapacity(classInfos.count + protocolInfos.count + categoryInfos.count)

    for info in classInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        if !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs("privateheaderkit __raw-dump: skip invalid class name: \(String(reflecting: info.name))\n", stderr)
            }
            continue
        }
        entries.append(
            SwiftObjCHeaderRendering.classEntry(
                info,
                runtimeOrigin: metadata.runtimeOriginClassNames.contains(info.name)
            )
        )
    }

    for info in protocolInfos.values {
        if let only = options.onlyOneClass, only != info.name { continue }
        if !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs("privateheaderkit __raw-dump: skip invalid protocol name: \(String(reflecting: info.name))\n", stderr)
            }
            continue
        }
        entries.append(SwiftObjCHeaderRendering.protocolEntry(info))
    }

    for info in categoryInfos.values {
        if let only = options.onlyOneClass, only != info.className && only != info.name { continue }
        if !isSaneObjCTypeName(info.className) || !isSaneObjCTypeName(info.name) {
            if options.verbose {
                fputs(
                    "privateheaderkit __raw-dump: skip invalid category name: class=\(String(reflecting: info.className)) category=\(String(reflecting: info.name))\n",
                    stderr
                )
            }
            continue
        }
        entries.append(SwiftObjCHeaderRendering.categoryEntry(info))
    }

    for entry in resolveObjCHeaderEntries(entries, options: options) {
        let fileURL = outputDir.appendingPathComponent(entry.fileName)
        try writeIfNeeded(text: entry.headerString, to: fileURL, options: options, fileManager: fileManager)
    }
}

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: RawMachO,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    switch machO {
    case .file(let file):
        collectClassInfos(classes, in: file, options: options, classInfos: &classInfos)
    case .loaded(let image):
        collectClassInfos(classes, in: image, options: options, classInfos: &classInfos)
    }
}

private func protocolInfo(
    _ proto: any ObjCProtocolProtocol,
    in machO: RawMachO,
    diagnostics: RawDumpObjCDiagnosticsAccumulator
) -> ObjCProtocolInfo? {
    let options = rawDumpObjCProtocolInfoOptions(for: .protocol)
    switch machO {
    case .file(let file):
        let result = proto.readInfo(in: file, options: options)
        diagnostics.append(contentsOf: result)
        return result.value
    case .loaded(let image):
        let result = proto.readInfo(in: image, options: options)
        diagnostics.append(contentsOf: result)
        return result.value
    }
}

private func categoryInfo(
    _ category: any ObjCCategoryProtocol,
    in machO: RawMachO,
    diagnostics: RawDumpObjCDiagnosticsAccumulator
) -> ObjCCategoryInfo? {
    let options = rawDumpObjCInfoOptions(for: .category)
    switch machO {
    case .file(let file):
        let result = category.readInfo(in: file, options: options)
        diagnostics.append(contentsOf: result)
        return result.value
    case .loaded(let image):
        let result = category.readInfo(in: image, options: options)
        diagnostics.append(contentsOf: result)
        return result.value
    }
}

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: MachOFile,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    let readOptions = rawDumpObjCInfoOptions(for: .class)
    for cls in classes {
        let result = cls.readInfo(in: machO, options: readOptions)
        options.objcDiagnostics.append(contentsOf: result)
        if let info = result.value {
            classInfos[info.name] = info
        } else if options.verbose && options.logSkippedClasses {
            logClassInfoFailure(cls, in: machO)
        }
    }
}

private func collectClassInfos<T: ObjCClassProtocol>(
    _ classes: [T],
    in machO: MachOImage,
    options: DumpOptions,
    classInfos: inout [String: ObjCClassInfo]
) {
    let readOptions = rawDumpObjCInfoOptions(for: .class)
    for cls in classes {
        let result = cls.readInfo(in: machO, options: readOptions)
        options.objcDiagnostics.append(contentsOf: result)
        if let info = result.value {
            classInfos[info.name] = info
        } else if options.verbose && options.logSkippedClasses {
            logClassInfoFailure(cls, in: machO)
        }
    }
}

private func logClassInfoFailure<T: ObjCClassProtocol>(
    _ cls: T,
    in machO: MachOFile
) {
    let data = cls.classROData(in: machO)
    let meta = cls.metaClass(in: machO)
    let metaData = meta.flatMap { $0.1.classROData(in: $0.0) }
    let name = data?.name(in: machO)
    var missing: [String] = []
    if data == nil { missing.append("classROData") }
    if meta == nil { missing.append("metaClass") }
    if metaData == nil { missing.append("metaClassROData") }
    if name == nil { missing.append("name") }
    let missingText = missing.isEmpty ? "unknown" : missing.joined(separator: ",")
    let displayName = name ?? "<unknown>"
    let metaImage = meta?.0.imagePath ?? "<nil>"
    fputs(
        "privateheaderkit __raw-dump: skip class \(displayName) (offset=\(cls.offset)) image=\(machO.imagePath) metaImage=\(metaImage) missing=\(missingText)\n",
        stderr
    )
}

private func logClassInfoFailure<T: ObjCClassProtocol>(
    _ cls: T,
    in machO: MachOImage
) {
    let data = cls.classROData(in: machO)
    let meta = cls.metaClass(in: machO)
    let metaData = meta.flatMap { $0.1.classROData(in: $0.0) }
    let name = data?.name(in: machO)
    var missing: [String] = []
    if data == nil { missing.append("classROData") }
    if meta == nil { missing.append("metaClass") }
    if metaData == nil { missing.append("metaClassROData") }
    if name == nil { missing.append("name") }
    let missingText = missing.isEmpty ? "unknown" : missing.joined(separator: ",")
    let displayName = name ?? "<unknown>"
    let imagePath = machO.path ?? "<unknown>"
    let metaImage = meta?.0.path ?? "<nil>"
    fputs(
        "privateheaderkit __raw-dump: skip class \(displayName) (offset=\(cls.offset)) image=\(imagePath) metaImage=\(metaImage) missing=\(missingText)\n",
        stderr
    )
}
