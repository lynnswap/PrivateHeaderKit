import Foundation

#if canImport(Darwin)
import Darwin
import MachO
#endif

package enum CurrentProcessExecutableIdentityError: Error, Equatable, Sendable {
    case imageInspectionFailed
    case missingMachOUUID
}

extension CurrentProcessExecutableIdentityError: CustomStringConvertible, LocalizedError {
    package var description: String {
        switch self {
        case .imageInspectionFailed:
            "failed to inspect the running executable image"
        case .missingMachOUUID:
            "the running executable has no Mach-O UUID"
        }
    }

    package var errorDescription: String? { description }
}

package func currentProcessMachOUUID() throws -> UUID {
#if canImport(Darwin)
    guard let header = _dyld_get_image_header(0),
          header.pointee.magic == MH_MAGIC_64
    else {
        throw CurrentProcessExecutableIdentityError.imageInspectionFailed
    }

    var cursor = UnsafeRawPointer(header).advanced(
        by: MemoryLayout<mach_header_64>.size
    )
    var remainingBytes = Int(header.pointee.sizeofcmds)
    for _ in 0..<header.pointee.ncmds {
        guard remainingBytes >= MemoryLayout<load_command>.size else { break }
        let command = cursor.loadUnaligned(as: load_command.self)
        let commandSize = Int(command.cmdsize)
        guard commandSize >= MemoryLayout<load_command>.size,
              commandSize <= remainingBytes
        else {
            break
        }
        if command.cmd == LC_UUID {
            guard commandSize >= MemoryLayout<uuid_command>.size else { break }
            let uuid = cursor.loadUnaligned(as: uuid_command.self).uuid
            return UUID(uuid: uuid)
        }
        cursor = cursor.advanced(by: commandSize)
        remainingBytes -= commandSize
    }
    throw CurrentProcessExecutableIdentityError.missingMachOUUID
#else
    throw CurrentProcessExecutableIdentityError.imageInspectionFailed
#endif
}
