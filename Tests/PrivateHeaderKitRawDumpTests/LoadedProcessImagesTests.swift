import Foundation
import MachOKit
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitRawDumpCore

#if canImport(Darwin)
import Darwin
import MachO

@Suite struct LoadedProcessImagesTests {
    @Test func discoveryUsesExecutableHeaderRatherThanImageOrderAndReportsPartialFailures() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let hook = fixture.image(fileType: UInt32(MH_DYLIB), uuid: fixture.otherUUID)
        fixture.memory.regions[fixture.hookAddress] = fixture.binary(fileType: UInt32(MH_DYLIB), uuid: fixture.otherUUID)
        fixture.memory.regions[fixture.hookPathAddress] = fixture.pathPage("/synthetic/Hook.dylib")
        fixture.configureInventory([
            (fixture.hookAddress, fixture.hookPathAddress), (fixture.loadAddress, fixture.pathAddress),
            (0x70000, fixture.hookPathAddress),
        ])

        let inventory = try fixture.process.images()
        #expect(inventory.images.count == 2)
        #expect(inventory.images[0].uuid == hook.uuid)
        #expect(inventory.images[0].fileType == UInt32(MH_DYLIB))
        #expect(inventory.images[1].uuid == fixture.uuid)
        #expect(inventory.images[1].fileType == UInt32(MH_EXECUTE))
        #expect(inventory.failures.count == 1)
        #expect(inventory.failures[0].loadAddress == 0x70000)
        #expect(inventory.failures[0].path == "/synthetic/Hook.dylib")
    }

    @Test func unencryptedImageIsCopiedWithoutReadingDataOrCryptRange() throws {
        let fixture = try ProcessImageFixture(encrypted: false)
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)

        #expect(report.encryptedBytesRecovered == 0)
        #expect(try Data(contentsOf: fixture.destination) == original)
        #expect(!fixture.memory.reads.contains { $0.address >= fixture.loadAddress + 0x1000 })
    }

    @Test func encryptedImageReplacesOnlyDeclaredRangeAndCryptID() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        let recovered = try Data(contentsOf: fixture.destination)
        var expected = original
        expected.replaceSubrange(0x1000..<0x1040, with: fixture.plaintext)
        expected.replaceSubrange(fixture.cryptIDOffset..<fixture.cryptIDOffset + 4, with: Data(repeating: 0, count: 4))

        #expect(recovered == expected)
        #expect(report.encryptedBytesRecovered == 64)
        #expect(report.image.uuid == fixture.uuid)
        #expect(report.outputPath == fixture.destination.path)
        #expect(!(try MachOFile(url: fixture.destination)).isEncrypted)
        #expect(try Data(contentsOf: fixture.source) == original)
    }

    @Test func memoryFailurePreservesPreviousOutputAndRemovesStaging() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let previous = Data("previous result".utf8)
        try previous.write(to: fixture.destination)
        fixture.memory.failureAddress = fixture.loadAddress + 0x1000

        #expect(throws: FakeProcessMemory.Failure.readRejected) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.destination) == previous)
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func diskUUIDMismatchDoesNotProduceOutput() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        try fixture.binary(uuid: fixture.otherUUID).write(to: fixture.source)
        #expect(throws: ProcessImageRecoveryError.imageIdentityMismatch) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func staleSelectionIsRejectedBeforeReadingOriginalFile() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        fixture.memory.regions[fixture.loadAddress] = fixture.binary(uuid: fixture.otherUUID)
        try FileManager.default.removeItem(at: fixture.source)
        #expect(throws: ProcessImageRecoveryError.imageIdentityMismatch) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
    }

    @Test func encryptedRangeOutsideFileIsRejectedWithoutPublishing() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        try fixture.binary(cryptOffset: 0x2ff0, cryptSize: 0x40).write(to: fixture.source)
        #expect(throws: ProcessImageRecoveryError.invalidMetadata("encrypted range exceeds original Mach-O slice")) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func encryptedRangeOutsideFileBackedVMMappingIsRejected() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        try fixture.binary(cryptOffset: 0x1ff0, cryptSize: 0x40).write(to: fixture.source)
        #expect(throws: ProcessImageRecoveryError.invalidMetadata("encrypted range has no complete file-backed VM mapping")) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func matchingUniversalSliceProducesThinImageRatherThanFirstSupportedArchitecture() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let first = fixture.binary(uuid: fixture.otherUUID)
        let active = fixture.binary()
        var universal = Data(repeating: 0, count: 0xb000)
        write(fat_header(magic: FAT_MAGIC.byteSwapped, nfat_arch: UInt32(2).byteSwapped), to: &universal, at: 0)
        for (index, offset) in [UInt32(0x4000), UInt32(0x8000)].enumerated() {
            write(fat_arch(cputype: CPU_TYPE_ARM64.byteSwapped,
                           cpusubtype: CPU_SUBTYPE_ARM64_ALL.byteSwapped,
                           offset: offset.byteSwapped, size: UInt32(active.count).byteSwapped,
                           align: UInt32(14).byteSwapped),
                  to: &universal, at: 8 + index * MemoryLayout<fat_arch>.size)
        }
        universal.replaceSubrange(0x4000..<0x4000 + first.count, with: first)
        universal.replaceSubrange(0x8000..<0x8000 + active.count, with: active)
        try universal.write(to: fixture.source)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        let output = try MachOFile(url: fixture.destination)
        #expect(output.loadCommands.info(of: LoadCommand.uuid)?.uuid == fixture.uuid)
        #expect(!output.isEncrypted)
        #expect(try Data(contentsOf: fixture.destination).count == active.count)
        #expect(report.encryptedBytesRecovered == 64)
    }

    @Test func matching64BitUniversalSliceUses64BitArchitectureOffsetsAndSizes() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let first = fixture.binary(uuid: fixture.otherUUID)
        let active = fixture.binary()
        var universal = Data(repeating: 0, count: 0xb000)
        write(fat_header(magic: FAT_MAGIC_64.byteSwapped, nfat_arch: UInt32(2).byteSwapped), to: &universal, at: 0)
        for (index, offset) in [UInt64(0x4000), UInt64(0x8000)].enumerated() {
            write(fat_arch_64(cputype: CPU_TYPE_ARM64.byteSwapped,
                              cpusubtype: CPU_SUBTYPE_ARM64_ALL.byteSwapped,
                              offset: offset.byteSwapped, size: UInt64(active.count).byteSwapped,
                              align: UInt32(14).byteSwapped, reserved: 0),
                  to: &universal, at: 8 + index * MemoryLayout<fat_arch_64>.size)
        }
        universal.replaceSubrange(0x4000..<0x4000 + first.count, with: first)
        universal.replaceSubrange(0x8000..<0x8000 + active.count, with: active)
        try universal.write(to: fixture.source)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        let output = try MachOFile(url: fixture.destination)
        #expect(output.loadCommands.info(of: LoadCommand.uuid)?.uuid == fixture.uuid)
        #expect(!output.isEncrypted)
        #expect(try Data(contentsOf: fixture.destination).count == active.count)
        #expect(report.encryptedBytesRecovered == 64)
    }

    @Test func truncatedTypedLoadCommandIsRejectedBeforeMachOKitAndKeepsPreviousOutput() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        var malformed = fixture.binary()
        let header = malformed.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        let commandOffset = MemoryLayout<mach_header_64>.size + Int(header.sizeofcmds)
        write(load_command(cmd: UInt32(LC_DYSYMTAB), cmdsize: UInt32(MemoryLayout<load_command>.size)),
              to: &malformed, at: commandOffset)
        write(header.ncmds + 1, to: &malformed, at: MemoryLayout<mach_header_64>.offset(of: \.ncmds)!)
        write(header.sizeofcmds + UInt32(MemoryLayout<load_command>.size),
              to: &malformed, at: MemoryLayout<mach_header_64>.offset(of: \.sizeofcmds)!)
        try malformed.write(to: fixture.source)
        let previous = Data("previous result".utf8)
        try previous.write(to: fixture.destination)
        #expect(throws: ProcessImageRecoveryError.invalidMetadata("invalid original Mach-O command size")) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(try Data(contentsOf: fixture.destination) == previous)
        #expect(try fixture.stagingNames().isEmpty)
    }

    @Test func hugeDyldCountReadsMappedRecordsWithoutAllocatingTheClaimedArray() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        fixture.configureInventory([(fixture.loadAddress, fixture.pathAddress)])
        var information = try #require(fixture.memory.regions[fixture.memory.dyldAddress])
        write(UInt32.max, to: &information, at: 4)
        fixture.memory.regions[fixture.memory.dyldAddress] = information
        #expect(throws: FakeProcessMemory.Failure.unavailable) {
            try fixture.process.images()
        }
        #expect(fixture.memory.reads.contains { $0.address == fixture.loadAddress })
        #expect(fixture.memory.reads.allSatisfy { $0.count <= Int(PATH_MAX) })
        #expect(fixture.memory.reads.contains { $0.address == 0xb0000 + UInt64(MemoryLayout<dyld_image_info>.size) })
    }

    @Test func originalFileAndParentDirectoryAliasCannotBeUsedAsDestination() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        #expect(throws: ProcessImageRecoveryError.outputIsOriginalFile) {
            try fixture.process.recover(image: fixture.image(), to: fixture.source)
        }
        let parentAlias = fixture.directory.appending(path: "ParentAlias")
        try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: fixture.directory)
        #expect(throws: ProcessImageRecoveryError.outputIsOriginalFile) {
            try fixture.process.recover(image: fixture.image(), to: parentAlias.appending(path: fixture.source.lastPathComponent))
        }
    }

    @Test func otherHardLinkDestinationIsReplacedWithoutChangingOriginal() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        try FileManager.default.linkItem(at: fixture.source, to: fixture.destination)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        #expect(report.encryptedBytesRecovered == 64)
        #expect(try Data(contentsOf: fixture.source) == original)
        #expect(!(try MachOFile(url: fixture.destination)).isEncrypted)
    }

    @Test func otherSymlinkDestinationIsReplacedWithoutChangingItsTarget() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        let original = try Data(contentsOf: fixture.source)
        try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: fixture.source)
        let report = try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        #expect(report.encryptedBytesRecovered == 64)
        #expect(try Data(contentsOf: fixture.source) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: fixture.destination.path)[.type] as? FileAttributeType == .typeRegular)
    }

    @Test func changingDyldTimestampDoesNotReturnAStaleInventory() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        fixture.configureInventory([(fixture.loadAddress, fixture.pathAddress)])
        fixture.memory.changeTimestampAfterRead = true
        #expect(throws: ProcessImageRecoveryError.imageArrayChanged) {
            try fixture.process.images()
        }
    }

    @Test func invalidOriginalCommandEnvelopeReturnsErrorInsteadOfPassingTruncatedCommandsToMachOKit() throws {
        let fixture = try ProcessImageFixture()
        defer { fixture.remove() }
        var malformed = fixture.binary()
        write(UInt32(0xffff_ffff), to: &malformed,
              at: MemoryLayout<mach_header_64>.offset(of: \.sizeofcmds)!)
        try malformed.write(to: fixture.source)
        #expect(throws: ProcessImageRecoveryError.invalidMetadata("invalid original Mach-O command envelope")) {
            try fixture.process.recover(image: fixture.image(), to: fixture.destination)
        }
        #expect(try fixture.stagingNames().isEmpty)
    }
}

private final class FakeProcessMemory: ProcessMemoryReading {
    enum Failure: Error, Equatable { case readRejected, unavailable }
    struct Read { let address: UInt64; let count: Int }
    var regions: [UInt64: Data] = [:]
    var reads: [Read] = []
    var failureAddress: UInt64?
    var changeTimestampAfterRead = false
    var timestampReadCount = 0
    let dyldAddress: UInt64 = 0x80000

    func dyldInformation() throws -> ProcessDyldInformation {
        .init(address: dyldAddress, size: UInt64(MemoryLayout<dyld_all_image_infos>.size),
              format: TASK_DYLD_ALL_IMAGE_INFO_64)
    }

    func read(address: UInt64, byteCount: Int) throws -> Data {
        reads.append(.init(address: address, count: byteCount))
        if address == failureAddress { throw Failure.readRejected }
        let timestampAddress = dyldAddress + UInt64(MemoryLayout<dyld_all_image_infos>.offset(of: \.infoArrayChangeTimestamp)!)
        if changeTimestampAfterRead && address == timestampAddress {
            timestampReadCount += 1
            var data = Data(count: 8)
            write(UInt64(timestampReadCount), to: &data, at: 0)
            return data
        }
        for (base, bytes) in regions where address >= base {
            let offset = address - base
            if offset <= UInt64(bytes.count), UInt64(byteCount) <= UInt64(bytes.count) - offset {
                return bytes.subdata(in: Int(offset)..<Int(offset) + byteCount)
            }
        }
        throw Failure.unavailable
    }
}

private final class ProcessImageFixture {
    let directory: URL
    let source: URL
    let destination: URL
    let memory = FakeProcessMemory()
    let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let otherUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    let loadAddress: UInt64 = 0x10000
    let hookAddress: UInt64 = 0x30000
    let pathAddress: UInt64 = 0x90000
    let hookPathAddress: UInt64 = 0xa0000
    let plaintext = Data(repeating: 0x5a, count: 64)
    var process: LoadedProcessImages { .init(processIdentifier: 1234, memory: memory) }
    var cryptIDOffset: Int {
        MemoryLayout<mach_header_64>.size + 2 * MemoryLayout<segment_command_64>.size
            + MemoryLayout<uuid_command>.size + MemoryLayout<encryption_info_command_64>.offset(of: \.cryptid)!
    }

    init(encrypted: Bool = true) throws {
        directory = URL.temporaryDirectory.appending(path: "phk-process-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        source = directory.appending(path: "SampleExecutable")
        destination = directory.appending(path: "Recovered.macho")
        let bytes = binary(encrypted: encrypted)
        try bytes.write(to: source)
        memory.regions[loadAddress] = bytes.prefix(0x1000)
        memory.regions[loadAddress + 0x1000] = plaintext
        memory.regions[pathAddress] = pathPage(source.path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
    func stagingNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".recovering") }
    }

    func image(fileType: UInt32 = UInt32(MH_EXECUTE), uuid: UUID? = nil) -> PrivateHeaderKitProcessImage {
        .init(loadAddress: loadAddress, path: source.path, uuid: uuid ?? self.uuid,
              cpuType: CPU_TYPE_ARM64, cpuSubtype: CPU_SUBTYPE_ARM64_ALL, fileType: fileType)
    }

    func binary(
        encrypted: Bool = true, fileType: UInt32 = UInt32(MH_EXECUTE), uuid: UUID? = nil,
        cryptOffset: UInt32 = 0x1000, cryptSize: UInt32 = 64
    ) -> Data {
        var data = Data(repeating: 0xa5, count: 0x3000)
        let segmentSize = MemoryLayout<segment_command_64>.size
        let commandBytes = 2 * segmentSize + MemoryLayout<uuid_command>.size + MemoryLayout<encryption_info_command_64>.size
        let header = mach_header_64(magic: MH_MAGIC_64, cputype: CPU_TYPE_ARM64,
                                   cpusubtype: CPU_SUBTYPE_ARM64_ALL, filetype: fileType,
                                   ncmds: 4, sizeofcmds: UInt32(commandBytes), flags: 0, reserved: 0)
        write(header, to: &data, at: 0)
        var offset = MemoryLayout<mach_header_64>.size
        for (name, vm, file, size) in [("__TEXT", UInt64(0x1_0000_0000), UInt64(0), UInt64(0x2000)),
                                       ("__DATA", UInt64(0x1_0000_2000), UInt64(0x2000), UInt64(0x1000))] {
            var segment = segment_command_64()
            segment.cmd = UInt32(LC_SEGMENT_64)
            segment.cmdsize = UInt32(segmentSize)
            segment.vmaddr = vm
            segment.vmsize = size
            segment.fileoff = file
            segment.filesize = size
            segment.maxprot = VM_PROT_READ | VM_PROT_EXECUTE
            segment.initprot = VM_PROT_READ
            withUnsafeMutableBytes(of: &segment.segname) { buffer in
                buffer.copyBytes(from: name.utf8)
            }
            write(segment, to: &data, at: offset)
            offset += segmentSize
        }
        write(uuid_command(cmd: UInt32(LC_UUID), cmdsize: UInt32(MemoryLayout<uuid_command>.size),
                           uuid: (uuid ?? self.uuid).uuid), to: &data, at: offset)
        offset += MemoryLayout<uuid_command>.size
        write(encryption_info_command_64(cmd: UInt32(LC_ENCRYPTION_INFO_64),
                                         cmdsize: UInt32(MemoryLayout<encryption_info_command_64>.size),
                                         cryptoff: cryptOffset, cryptsize: cryptSize,
                                         cryptid: encrypted ? 1 : 0, pad: 0), to: &data, at: offset)
        data.replaceSubrange(0x2000..<0x3000, with: Data(repeating: 0xdd, count: 0x1000))
        return data
    }

    func pathPage(_ path: String) -> Data {
        var bytes = Data(repeating: 0, count: Int(getpagesize()))
        bytes.replaceSubrange(0..<path.utf8.count, with: path.utf8)
        return bytes
    }

    func configureInventory(_ entries: [(UInt64, UInt64)]) {
        var information = Data(count: MemoryLayout<dyld_all_image_infos>.size)
        write(UInt32(15), to: &information, at: 0)
        write(UInt32(entries.count), to: &information, at: 4)
        write(UInt64(0xb0000), to: &information, at: 8)
        memory.regions[memory.dyldAddress] = information
        var array = Data(count: entries.count * MemoryLayout<dyld_image_info>.size)
        for (index, (address, path)) in entries.enumerated() {
            let entry = dyld_image_info(imageLoadAddress: UnsafePointer<mach_header>(bitPattern: UInt(address)),
                                        imageFilePath: UnsafePointer<CChar>(bitPattern: UInt(path)), imageFileModDate: 0)
            write(entry, to: &array, at: index * MemoryLayout<dyld_image_info>.size)
        }
        memory.regions[0xb0000] = array
    }
}

private func write<Value>(_ value: Value, to data: inout Data, at offset: Int) {
    withUnsafeBytes(of: value) { bytes in
        data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}
#endif
