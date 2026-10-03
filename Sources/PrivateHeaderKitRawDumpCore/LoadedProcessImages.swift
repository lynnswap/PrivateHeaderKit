import Foundation
import MachOKit
import PrivateHeaderKitHelperProtocol

#if canImport(Darwin)
import Darwin
import MachO

struct ProcessDyldInformation {
    let address: UInt64
    let size: UInt64
    let format: Int32
}

protocol ProcessMemoryReading {
    func dyldInformation() throws -> ProcessDyldInformation
    func read(address: UInt64, byteCount: Int) throws -> Data
}

package final class LoadedProcessImages {
    private let processIdentifier: Int32
    private let memory: any ProcessMemoryReading

    init(processIdentifier: Int32, memory: any ProcessMemoryReading) {
        self.processIdentifier = processIdentifier
        self.memory = memory
    }

    /// The task port is released before returning, including when the body fails.
    package static func withProcess<Result>(
        processIdentifier: Int32,
        body: (LoadedProcessImages) throws -> Result
    ) throws -> Result {
        let memory = try MachProcessMemoryReader(processIdentifier: processIdentifier)
        let result: Result
        do {
            result = try body(LoadedProcessImages(processIdentifier: processIdentifier, memory: memory))
        } catch {
            do {
                try memory.close()
            } catch let cleanupError {
                throw ProcessImageCleanupError(operationError: error, cleanupError: cleanupError, remainingPath: nil)
            }
            throw error
        }
        try memory.close()
        return result
    }

    package func images() throws -> PrivateHeaderKitProcessImageInventory {
        let information = try memory.dyldInformation()
        guard information.format == TASK_DYLD_ALL_IMAGE_INFO_64 else {
            throw ProcessImageRecoveryError.unsupportedDyldFormat(information.format)
        }
        let before = try imageArrayState(information)
        let entrySize = MemoryLayout<dyld_image_info>.size
        guard before.address != 0 else {
            throw ProcessImageRecoveryError.invalidMetadata("dyld image array is unavailable")
        }
        var images: [PrivateHeaderKitProcessImage] = []
        var failures: [PrivateHeaderKitProcessImageFailure] = []
        for index in 0..<Int(before.count) {
            let entryAddress = try adding(before.address, UInt64(index) * UInt64(entrySize))
            let array = try memory.read(address: entryAddress, byteCount: entrySize)
            try requireByteCount(array, entrySize)
            let entry: dyld_image_info = array.withUnsafeBytes {
                $0.loadUnaligned(as: dyld_image_info.self)
            }
            let address = UInt64(UInt(bitPattern: entry.imageLoadAddress))
            var path: String?
            do {
                let imagePath = try readPath(address: UInt64(UInt(bitPattern: entry.imageFilePath)))
                path = imagePath
                let identity = try readIdentity(at: address)
                images.append(identity.image(loadAddress: address, path: imagePath))
            } catch {
                failures.append(.init(loadAddress: address, path: path, error: String(describing: error)))
            }
        }
        guard try imageArrayState(information) == before else {
            throw ProcessImageRecoveryError.imageArrayChanged
        }
        return try .init(processIdentifier: processIdentifier, images: images, failures: failures)
    }

    /// Produces a thin analysis copy, retaining file-backed fixups and replacing only encrypted ranges.
    /// An existing destination remains intact if recovery fails before publication.
    package func recover(
        image: PrivateHeaderKitProcessImage,
        to destination: URL
    ) throws -> PrivateHeaderKitRecoveredProcessImage {
        let current = try readIdentity(at: image.loadAddress)
        try current.requireMatch(image)
        let source = URL(filePath: image.path)
        try requireDistinctFile(source, destination)
        let staging = destination.deletingLastPathComponent().appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).recovering"
        )
        do {
            try copyActiveSlice(from: source, to: staging, matching: current)
            let fileSize = try size(of: staging)
            try validateFileCommands(at: staging, offset: 0, size: fileSize)
            let file = try MachOFile(url: staging)
            try requireMatch(file, current)
            let recovered = try recoverEncryptedRanges(in: file, fileSize: fileSize, loadAddress: image.loadAddress)
            try readIdentity(at: image.loadAddress).requireMatch(image)
            let report = try PrivateHeaderKitRecoveredProcessImage(
                processIdentifier: processIdentifier, image: image, outputPath: destination.path,
                encryptedBytesRecovered: recovered
            )
            guard rename(staging.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return report
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) {
                do {
                    try FileManager.default.removeItem(at: staging)
                } catch let cleanupError {
                    throw ProcessImageCleanupError(
                        operationError: error, cleanupError: cleanupError, remainingPath: staging.path
                    )
                }
            }
            throw error
        }
    }

    private struct ImageArrayState: Equatable {
        let count: UInt32
        let address: UInt64
        let timestamp: UInt64?
    }

    private func imageArrayState(_ information: ProcessDyldInformation) throws -> ImageArrayState {
        let prefixSize = 16
        guard information.size >= UInt64(prefixSize) else {
            throw ProcessImageRecoveryError.invalidMetadata("truncated dyld information")
        }
        let prefix = try memory.read(address: information.address, byteCount: prefixSize)
        try requireByteCount(prefix, prefixSize)
        let version: UInt32 = load(prefix, at: 0)
        let count: UInt32 = load(prefix, at: 4)
        let arrayAddress: UInt64 = load(prefix, at: 8)
        var timestamp: UInt64?
        if version >= 15 {
            let offset = MemoryLayout<dyld_all_image_infos>.offset(of: \.infoArrayChangeTimestamp)!
            guard information.size >= UInt64(offset + MemoryLayout<UInt64>.size) else {
                throw ProcessImageRecoveryError.invalidMetadata("truncated dyld change timestamp")
            }
            let bytes = try memory.read(address: try adding(information.address, UInt64(offset)), byteCount: 8)
            try requireByteCount(bytes, 8)
            let value: UInt64 = load(bytes, at: 0)
            timestamp = value
        }
        return .init(count: count, address: arrayAddress, timestamp: timestamp)
    }

    private func readPath(address: UInt64) throws -> String {
        guard address != 0 else {
            throw ProcessImageRecoveryError.invalidMetadata("dyld image path is unavailable")
        }
        var bytes = Data()
        let pageSize = UInt64(getpagesize())
        while bytes.count < Int(PATH_MAX) {
            let cursor = try adding(address, UInt64(bytes.count))
            let count = min(Int(pageSize - cursor % pageSize), Int(PATH_MAX) - bytes.count)
            let next = try memory.read(address: cursor, byteCount: count)
            try requireByteCount(next, count)
            if let end = next.firstIndex(of: 0) {
                bytes.append(next[..<end])
                guard let path = String(data: bytes, encoding: .utf8), !path.isEmpty else {
                    throw ProcessImageRecoveryError.invalidMetadata("invalid dyld image path")
                }
                return path
            }
            bytes.append(next)
        }
        throw ProcessImageRecoveryError.invalidMetadata("dyld image path exceeds PATH_MAX")
    }

    private struct ImageIdentity {
        let uuid: UUID
        let header: mach_header_64

        func image(loadAddress: UInt64, path: String) -> PrivateHeaderKitProcessImage {
            .init(loadAddress: loadAddress, path: path, uuid: uuid,
                  cpuType: header.cputype, cpuSubtype: header.cpusubtype, fileType: header.filetype)
        }

        func requireMatch(_ image: PrivateHeaderKitProcessImage) throws {
            guard uuid == image.uuid, header.cputype == image.cpuType,
                  header.cpusubtype == image.cpuSubtype, header.filetype == image.fileType else {
                throw ProcessImageRecoveryError.imageIdentityMismatch
            }
        }
    }

    private func readIdentity(at address: UInt64) throws -> ImageIdentity {
        let headerSize = MemoryLayout<mach_header_64>.size
        let bytes = try memory.read(address: address, byteCount: headerSize)
        try requireByteCount(bytes, headerSize)
        let header: mach_header_64 = load(bytes, at: 0)
        guard header.magic == MH_MAGIC_64 else {
            throw ProcessImageRecoveryError.invalidMetadata("loaded image is not a native 64-bit Mach-O")
        }
        guard header.ncmds <= header.sizeofcmds / UInt32(MemoryLayout<load_command>.size) else {
            throw ProcessImageRecoveryError.invalidMetadata("invalid loaded Mach-O command count")
        }
        var offset = UInt64(headerSize)
        let end = try adding(offset, UInt64(header.sizeofcmds))
        var uuid: UUID?
        for _ in 0..<header.ncmds {
            guard offset <= end, end - offset >= UInt64(MemoryLayout<load_command>.size) else {
                throw ProcessImageRecoveryError.invalidMetadata("truncated loaded Mach-O command")
            }
            let bytes = try memory.read(address: try adding(address, offset), byteCount: MemoryLayout<load_command>.size)
            try requireByteCount(bytes, MemoryLayout<load_command>.size)
            let command: load_command = load(bytes, at: 0)
            guard command.cmdsize >= MemoryLayout<load_command>.size, UInt64(command.cmdsize) <= end - offset else {
                throw ProcessImageRecoveryError.invalidMetadata("invalid loaded Mach-O command size")
            }
            if command.cmd == LC_UUID {
                guard command.cmdsize >= MemoryLayout<uuid_command>.size, uuid == nil else {
                    throw ProcessImageRecoveryError.invalidMetadata("invalid loaded Mach-O UUID command")
                }
                let bytes = try memory.read(address: try adding(address, offset), byteCount: MemoryLayout<uuid_command>.size)
                try requireByteCount(bytes, MemoryLayout<uuid_command>.size)
                let command: uuid_command = load(bytes, at: 0)
                uuid = UUID(uuid: command.uuid)
            }
            offset = try adding(offset, UInt64(command.cmdsize))
        }
        guard let uuid else {
            throw ProcessImageRecoveryError.invalidMetadata("loaded image has no UUID")
        }
        return .init(uuid: uuid, header: header)
    }

    private func copyActiveSlice(from source: URL, to destination: URL, matching image: ImageIdentity) throws {
        let fileSize = try size(of: source)
        guard fileSize >= UInt64(MemoryLayout<mach_header_64>.size) else {
            throw ProcessImageRecoveryError.invalidMetadata("truncated original Mach-O file")
        }
        let original = try loadFromFile(url: source)
        let offset: UInt64
        let length: UInt64
        switch original {
        case .machO(let file):
            try validateFileCommands(at: source, offset: 0, size: fileSize)
            try requireMatch(file, image)
            offset = 0
            length = fileSize
        case .fat(let fat):
            guard UInt64(fat.archesStartOffset) <= fileSize,
                  UInt64(fat.archesSize) <= fileSize - UInt64(fat.archesStartOffset) else {
                throw ProcessImageRecoveryError.invalidMetadata("truncated universal architecture table")
            }
            var matches: [(offset: UInt64, size: UInt64)] = []
            try forEachUniversalSlice(in: fat) { arch in
                guard arch.cpuType == image.header.cputype,
                      arch.cpuSubtype == image.header.cpusubtype else { return }
                let sliceOffset = arch.offset
                let sliceSize = arch.size
                guard sliceOffset <= fileSize, sliceSize <= fileSize - sliceOffset else {
                    throw ProcessImageRecoveryError.invalidMetadata("universal slice exceeds original file")
                }
                try validateFileCommands(at: source, offset: sliceOffset, size: sliceSize)
                let file = try MachOFile(url: source, headerStartOffset: Int(sliceOffset))
                if file.loadCommands.info(of: LoadCommand.uuid)?.uuid == image.uuid {
                    try requireMatch(file, image)
                    matches.append((sliceOffset, sliceSize))
                }
            }
            guard matches.count == 1, let match = matches.first else {
                throw ProcessImageRecoveryError.imageIdentityMismatch
            }
            offset = match.offset
            length = match.size
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        try withWritingFile(output) {
            try input.seek(toOffset: offset)
            var copied: UInt64 = 0
            while copied < length {
                let count = Int(min(length - copied, UInt64(Self.copyChunkSize)))
                guard let bytes = try input.read(upToCount: count), bytes.count == count else {
                    throw ProcessImageRecoveryError.invalidMetadata("original Mach-O changed or was truncated during copy")
                }
                try output.write(contentsOf: bytes)
                copied += UInt64(count)
            }
        }
        try input.close()
    }

    private func requireMatch(_ file: MachOFile, _ image: ImageIdentity) throws {
        guard file.is64Bit, !file.isSwapped, file.loadCommands.info(of: LoadCommand.uuid)?.uuid == image.uuid,
              file.header.layout.cputype == image.header.cputype,
              file.header.layout.cpusubtype == image.header.cpusubtype,
              file.header.layout.filetype == image.header.filetype else {
            throw ProcessImageRecoveryError.imageIdentityMismatch
        }
    }

    private func recoverEncryptedRanges(in file: MachOFile, fileSize: UInt64, loadAddress: UInt64) throws -> UInt64 {
        guard file.isEncrypted else { return 0 }
        guard let headerSegment = file.segments64.first(where: {
            $0.layout.fileoff == 0 && $0.layout.filesize >= UInt64(file.headerSize)
        }) else {
            throw ProcessImageRecoveryError.invalidMetadata("original Mach-O header has no file-backed mapping")
        }
        let commands = file.loadCommands.compactMap { command -> EncryptionInfoCommand64? in
            if case .encryptionInfo64(let info) = command { return info }
            return nil
        }
        guard !commands.isEmpty else {
            throw ProcessImageRecoveryError.invalidMetadata("64-bit Mach-O has no 64-bit encryption command")
        }
        let output = try FileHandle(forWritingTo: file.url)
        return try withWritingFile(output) {
            var recovered: UInt64 = 0
            for command in commands where command.isEncrypted {
                let offset = UInt64(command.layout.cryptoff)
                let length = UInt64(command.layout.cryptsize)
                guard offset <= fileSize, length <= fileSize - offset else {
                    throw ProcessImageRecoveryError.invalidMetadata("encrypted range exceeds original Mach-O slice")
                }
                if length > 0 {
                    guard let segment = file.segments64.first(where: {
                        offset >= $0.layout.fileoff && offset - $0.layout.fileoff <= $0.layout.filesize
                            && length <= $0.layout.filesize - (offset - $0.layout.fileoff)
                            && offset - $0.layout.fileoff <= $0.layout.vmsize
                            && length <= $0.layout.vmsize - (offset - $0.layout.fileoff)
                    }) else {
                        throw ProcessImageRecoveryError.invalidMetadata("encrypted range has no complete file-backed VM mapping")
                    }
                    let preferred = try adding(segment.layout.vmaddr, offset - segment.layout.fileoff)
                    let base = headerSegment.layout.vmaddr
                    let address: UInt64
                    if preferred >= base {
                        address = try adding(loadAddress, preferred - base)
                    } else {
                        guard loadAddress >= base - preferred else {
                            throw ProcessImageRecoveryError.invalidMetadata("encrypted VM address underflows")
                        }
                        address = loadAddress - (base - preferred)
                    }
                    _ = try adding(address, length)
                    try output.seek(toOffset: offset)
                    var copied: UInt64 = 0
                    while copied < length {
                        let count = Int(min(length - copied, UInt64(Self.copyChunkSize)))
                        let bytes = try memory.read(address: try adding(address, copied), byteCount: count)
                        try requireByteCount(bytes, count)
                        try output.write(contentsOf: bytes)
                        copied += UInt64(count)
                    }
                    recovered = try adding(recovered, length)
                }
                let cryptIDOffset = file.headerSize + command.offset
                    + MemoryLayout<encryption_info_command_64>.offset(of: \.cryptid)!
                try output.seek(toOffset: UInt64(cryptIDOffset))
                try output.write(contentsOf: Data(repeating: 0, count: MemoryLayout<UInt32>.size))
            }
            return recovered
        }
    }

    // Chunking bounds transient storage without limiting a valid image's declared size.
    private static let copyChunkSize = 1_024 * 1_024
}

private struct UniversalSlice {
    let cpuType: Int32
    let cpuSubtype: Int32
    let offset: UInt64
    let size: UInt64
}

private func forEachUniversalSlice(in file: FatFile, body: (UniversalSlice) throws -> Void) throws {
    guard file.is64bit else {
        for arch in file.arches {
            try body(.init(cpuType: arch.layout.cputype, cpuSubtype: arch.layout.cpusubtype,
                           offset: UInt64(arch.offset), size: UInt64(arch.size)))
        }
        return
    }
    // MachOKit's FAT64 arches currently reinterpret fat_arch_64 as fat_arch,
    // which loses the 64-bit offsets and sizes. Read that SDK layout directly.
    let input = try FileHandle(forReadingFrom: file.url)
    defer { try? input.close() }
    try input.seek(toOffset: UInt64(file.archesStartOffset))
    for _ in 0..<file.header.layout.nfat_arch {
        let size = MemoryLayout<fat_arch_64>.size
        guard let bytes = try input.read(upToCount: size), bytes.count == size else {
            throw ProcessImageRecoveryError.invalidMetadata("truncated universal architecture record")
        }
        let arch: fat_arch_64 = load(bytes, at: 0)
        try body(.init(
            cpuType: file.isSwapped ? arch.cputype.byteSwapped : arch.cputype,
            cpuSubtype: file.isSwapped ? arch.cpusubtype.byteSwapped : arch.cpusubtype,
            offset: file.isSwapped ? arch.offset.byteSwapped : arch.offset,
            size: file.isSwapped ? arch.size.byteSwapped : arch.size
        ))
    }
}

// MachOKit's file loadCommands uses try! for the byte read and its iterator dereferences
// command layouts without checking cmdsize. Validate that byte envelope before decoding.
private func validateFileCommands(at url: URL, offset: UInt64, size: UInt64) throws {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    try input.seek(toOffset: offset)
    let headerSize = MemoryLayout<mach_header_64>.size
    guard size >= UInt64(headerSize), let bytes = try input.read(upToCount: headerSize), bytes.count == headerSize else {
        throw ProcessImageRecoveryError.invalidMetadata("truncated original Mach-O header")
    }
    let header: mach_header_64 = load(bytes, at: 0)
    guard header.magic == MH_MAGIC_64, UInt64(header.sizeofcmds) <= size - UInt64(headerSize),
          header.ncmds <= header.sizeofcmds / UInt32(MemoryLayout<load_command>.size) else {
        throw ProcessImageRecoveryError.invalidMetadata("invalid original Mach-O command envelope")
    }
    let end = UInt64(headerSize) + UInt64(header.sizeofcmds)
    var position = UInt64(headerSize)
    for _ in 0..<header.ncmds {
        guard position <= end, end - position >= UInt64(MemoryLayout<load_command>.size) else {
            throw ProcessImageRecoveryError.invalidMetadata("truncated original Mach-O command")
        }
        try input.seek(toOffset: try adding(offset, position))
        guard let bytes = try input.read(upToCount: MemoryLayout<load_command>.size), bytes.count == MemoryLayout<load_command>.size else {
            throw ProcessImageRecoveryError.invalidMetadata("truncated original Mach-O command")
        }
        let command: load_command = load(bytes, at: 0)
        let minimumSize = try minimumCommandSize(command.cmd)
        guard command.cmdsize >= minimumSize, UInt64(command.cmdsize) <= end - position else {
            throw ProcessImageRecoveryError.invalidMetadata("invalid original Mach-O command size")
        }
        position += UInt64(command.cmdsize)
    }
}

private func minimumCommandSize(_ rawValue: UInt32) throws -> Int {
    guard let type = LoadCommandType(rawValue: rawValue) ?? LoadCommandType(rawValue: rawValue.byteSwapped) else {
        return MemoryLayout<load_command>.size
    }
    switch type {
    case .segment: return MemoryLayout<segment_command>.size
    case .segment64: return MemoryLayout<segment_command_64>.size
    case .symtab: return MemoryLayout<symtab_command>.size
    case .symseg: return MemoryLayout<symseg_command>.size
    case .thread, .unixthread: return MemoryLayout<thread_command>.size
    case .loadfvmlib, .idfvmlib: return MemoryLayout<fvmlib_command>.size
    case .ident: return MemoryLayout<ident_command>.size
    case .fvmfile: return MemoryLayout<fvmfile_command>.size
    case .prepage: return MemoryLayout<load_command>.size
    case .dysymtab: return MemoryLayout<dysymtab_command>.size
    case .loadDylib, .idDylib, .loadWeakDylib, .reexportDylib, .lazyLoadDylib, .loadUpwardDylib:
        return MemoryLayout<dylib_command>.size
    case .loadDylinker, .idDylinker, .dyldEnvironment: return MemoryLayout<dylinker_command>.size
    case .preboundDylib: return MemoryLayout<prebound_dylib_command>.size
    case .routines: return MemoryLayout<routines_command>.size
    case .routines64: return MemoryLayout<routines_command_64>.size
    case .subFramework: return MemoryLayout<sub_framework_command>.size
    case .subUmbrella: return MemoryLayout<sub_umbrella_command>.size
    case .subClient: return MemoryLayout<sub_client_command>.size
    case .subLibrary: return MemoryLayout<sub_library_command>.size
    case .twolevelHints: return MemoryLayout<twolevel_hints_command>.size
    case .prebindCksum: return MemoryLayout<prebind_cksum_command>.size
    case .uuid: return MemoryLayout<uuid_command>.size
    case .rpath: return MemoryLayout<rpath_command>.size
    case .codeSignature, .segmentSplitInfo, .functionStarts, .dataInCode, .dylibCodeSignDrs,
         .linkerOptimizationHint, .dyldExportsTrie, .dyldChainedFixups, .atomInfo,
         .functionVariants, .functionVariantFixups, .lazyLoadDylibInfo:
        return MemoryLayout<linkedit_data_command>.size
    case .encryptionInfo: return MemoryLayout<encryption_info_command>.size
    case .encryptionInfo64: return MemoryLayout<encryption_info_command_64>.size
    case .dyldInfo, .dyldInfoOnly: return MemoryLayout<dyld_info_command>.size
    case .versionMinMacosx, .versionMinIphoneos, .versionMinTvos, .versionMinWatchos:
        return MemoryLayout<version_min_command>.size
    case .main: return MemoryLayout<entry_point_command>.size
    case .sourceVersion: return MemoryLayout<source_version_command>.size
    case .linkerOption: return MemoryLayout<linker_option_command>.size
    case .note: return MemoryLayout<note_command>.size
    case .buildVersion: return MemoryLayout<build_version_command>.size
    case .filesetEntry: return MemoryLayout<fileset_entry_command>.size
    case .targetTriple: return MemoryLayout<TargetTripleCommand.Layout>.size
    case .aotMetadata: return MemoryLayout<AotMetadataCommand.Layout>.size
    @unknown default:
        throw ProcessImageRecoveryError.invalidMetadata("unsupported MachOKit load command layout")
    }
}

private func requireDistinctFile(_ source: URL, _ destination: URL) throws {
    let destinationEntry = try directoryEntry(of: destination, allowingMissing: true)
    let sourceEntry = try directoryEntry(of: source)
    let sourceTarget = try directoryEntry(of: source.resolvingSymlinksInPath())
    guard destinationEntry != sourceEntry, destinationEntry != sourceTarget else {
        throw ProcessImageRecoveryError.outputIsOriginalFile
    }
}

private func directoryEntry(of url: URL, allowingMissing: Bool = false) throws -> URL {
    let name: String
    do {
        name = try url.resourceValues(forKeys: [.nameKey]).name ?? url.lastPathComponent
    } catch let error as CocoaError where allowingMissing && error.code == .fileReadNoSuchFile {
        name = url.lastPathComponent
    }
    // rename replaces this directory entry, rather than following its final symlink.
    return url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: name)
}

private func withWritingFile<Value>(_ file: FileHandle, body: () throws -> Value) throws -> Value {
    let outcome = Result { try body() }
    do {
        try file.close()
    } catch {
        if case .failure(let operationError) = outcome {
            throw ProcessImageCleanupError(operationError: operationError, cleanupError: error, remainingPath: nil)
        }
        throw error
    }
    return try outcome.get()
}

private func size(of url: URL) throws -> UInt64 {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    return try input.seekToEnd()
}

private func load<Value>(_ data: Data, at offset: Int) -> Value {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Value.self) }
}

private func requireByteCount(_ data: Data, _ expected: Int) throws {
    guard data.count == expected else {
        throw ProcessImageRecoveryError.shortMemoryRead(expected: expected, actual: data.count)
    }
}

private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else {
        throw ProcessImageRecoveryError.invalidMetadata("Mach-O address or range overflows")
    }
    return result
}

enum ProcessImageRecoveryError: Error, Equatable, CustomStringConvertible {
    case unsupportedDyldFormat(Int32)
    case invalidMetadata(String)
    case imageArrayChanged
    case imageIdentityMismatch
    case outputIsOriginalFile
    case shortMemoryRead(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .unsupportedDyldFormat(let format): "unsupported dyld image information format: \(format)"
        case .invalidMetadata(let reason): reason
        case .imageArrayChanged: "dyld image array changed during inspection; inspect the process again"
        case .imageIdentityMismatch: "loaded image UUID or CPU identity no longer matches the selected image or original file"
        case .outputIsOriginalFile: "recovery destination is the original image file"
        case .shortMemoryRead(let expected, let actual): "short process memory read: expected \(expected) bytes, received \(actual)"
        }
    }
}

struct ProcessImageCleanupError: Error, CustomStringConvertible {
    let operationError: any Error
    let cleanupError: any Error
    let remainingPath: String?

    var description: String {
        "\(operationError); cleanup failed: \(cleanupError)"
            + (remainingPath.map { "; remaining staging file: \($0)" } ?? "")
    }
}
#endif
