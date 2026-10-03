import Foundation
import PrivateHeaderKitExecutableResolution
import Testing

#if canImport(Darwin)
import Darwin
import MachO

@Suite
struct CurrentProcessExecutableIdentityTests {
    @Test func executableUUIDComesFromTheSuppliedExecutableHeader() throws {
        let dylibUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let executableUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        try withMachOHeader(fileType: MH_DYLIB, uuid: dylibUUID) { earlierImage in
            try withMachOHeader(fileType: MH_EXECUTE, uuid: executableUUID) { executable in
                let earlierImageUUID = try currentProcessMachOUUID(executableHeader: earlierImage)
                let resolvedExecutableUUID = try currentProcessMachOUUID(executableHeader: executable)
                #expect(earlierImageUUID == dylibUUID)
                #expect(resolvedExecutableUUID == executableUUID)
            }
        }
    }

    @Test func missingExecutableHeaderPreservesImageInspectionError() {
        #expect(throws: CurrentProcessExecutableIdentityError.imageInspectionFailed) {
            try currentProcessMachOUUID(executableHeader: nil)
        }
    }

    @Test func unsupportedExecutableHeaderPreservesImageInspectionError() {
        withMachOHeader(magic: MH_MAGIC, uuid: UUID()) { header in
            #expect(throws: CurrentProcessExecutableIdentityError.imageInspectionFailed) {
                try currentProcessMachOUUID(executableHeader: header)
            }
        }
    }

    @Test func missingExecutableUUIDPreservesMissingUUIDError() {
        withMachOHeader(uuid: nil) { header in
            #expect(throws: CurrentProcessExecutableIdentityError.missingMachOUUID) {
                try currentProcessMachOUUID(executableHeader: header)
            }
        }
    }
}

private func withMachOHeader(
    magic: UInt32 = MH_MAGIC_64,
    fileType: Int32 = MH_EXECUTE,
    uuid: UUID?,
    body: (UnsafePointer<mach_header_64>) throws -> Void
) rethrows {
    let commandSize = uuid == nil ? 0 : MemoryLayout<uuid_command>.size
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: MemoryLayout<mach_header_64>.size + commandSize,
        alignment: MemoryLayout<mach_header_64>.alignment
    )
    defer { storage.deallocate() }
    let header = storage.bindMemory(to: mach_header_64.self, capacity: 1)
    header.initialize(
        to: mach_header_64(
            magic: magic,
            cputype: CPU_TYPE_ARM64,
            cpusubtype: CPU_SUBTYPE_ARM64_ALL,
            filetype: UInt32(fileType),
            ncmds: uuid == nil ? 0 : 1,
            sizeofcmds: UInt32(commandSize),
            flags: 0,
            reserved: 0
        )
    )
    if let uuid {
        storage.advanced(by: MemoryLayout<mach_header_64>.size).storeBytes(
            of: uuid_command(cmd: UInt32(LC_UUID), cmdsize: UInt32(commandSize), uuid: uuid.uuid),
            as: uuid_command.self
        )
    }
    try body(UnsafePointer(header))
}
#endif
