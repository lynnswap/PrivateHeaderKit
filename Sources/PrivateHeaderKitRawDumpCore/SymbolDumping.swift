import Demangling
import Foundation
import MachOKit
import PrivateHeaderKitHelperProtocol
#if canImport(PrivateHeaderKitRawDumpRuntimeObjC)
import PrivateHeaderKitRawDumpRuntimeObjC
#endif

func demangleSearchableSymbol(_ name: String) -> String {
    if name.hasPrefix("__Z") || name.hasPrefix("_Z") {
        #if canImport(PrivateHeaderKitRawDumpRuntimeObjC)
        return name.withCString { PHKDemangleCXXName($0) } ?? name
        #else
        return name
        #endif
    }
    if name.hasPrefix("_$s") || name.hasPrefix("$s")
        || name.hasPrefix("_$S") || name.hasPrefix("$S") || name.hasPrefix("_T") {
        return (try? demangleAsNode(name, internsSubtrees: false).print(using: .default)) ?? name
    }
    return name
}

func searchableSymbolVisibility(
    flags: SymbolFlags,
    hasExportTrie: Bool
) -> PrivateHeaderKitSymbol.Visibility? {
    guard flags.rawValue & N_STAB == 0 else { return nil }
    switch flags.type {
    case .sect, .abs, .indr:
        return !hasExportTrie && flags.contains(.ext) && !flags.contains(.pext) ? .export : .local
    default:
        return nil
    }
}

func makeSearchableSymbolList<MachO: MachORepresentable>(
    machO: MachO,
    imagePath: String
) -> PrivateHeaderKitSymbolList {
    var visibilityByName: [String: PrivateHeaderKitSymbol.Visibility] = [:]
    let hasExportTrie = machO.exportTrie != nil
    for symbol in machO.symbols {
        guard !symbol.name.isEmpty, let flags = symbol.nlist.flags,
              let visibility = searchableSymbolVisibility(flags: flags, hasExportTrie: hasExportTrie)
        else { continue }
        if visibilityByName[symbol.name] != .export {
            visibilityByName[symbol.name] = visibility
        }
    }
    for symbol in machO.exportedSymbols where !symbol.name.isEmpty {
        visibilityByName[symbol.name] = .export
    }
    return PrivateHeaderKitSymbolList(
        imagePath: imagePath,
        symbols: visibilityByName.sorted(by: { $0.key < $1.key }).map { name, visibility in
            PrivateHeaderKitSymbol(
                name: name,
                demangledName: demangleSearchableSymbol(name),
                visibility: visibility
            )
        }
    )
}

func dumpSymbols(machO: RawMachO, imagePath: String, outputDir: URL, options: DumpOptions) throws {
    let fileName = safeFileName(
        baseName: URL(fileURLWithPath: imagePath).lastPathComponent,
        extension: ".symbols.tsv"
    )
    let outputURL = outputDir.appendingPathComponent(fileName)
    if options.skipExisting && FileManager.default.fileExists(atPath: outputURL.path) { return }
    let list: PrivateHeaderKitSymbolList
    switch machO {
    case .file(let file): list = makeSearchableSymbolList(machO: file, imagePath: imagePath)
    case .loaded(let image): list = makeSearchableSymbolList(machO: image, imagePath: imagePath)
    }
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    try list.tsv.write(to: outputURL, atomically: true, encoding: .utf8)
}
