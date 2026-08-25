import Foundation

#if canImport(Darwin)
import Darwin
import MachO
#endif

package enum CurrentProcessExecutableIdentityError: Error, Equatable, Sendable {
    case executablePathInspectionFailed
    case imageInspectionFailed
    case missingExecutableName
    case missingMachOUUID
}

extension CurrentProcessExecutableIdentityError: CustomStringConvertible, LocalizedError {
    package var description: String {
        switch self {
        case .executablePathInspectionFailed:
            "failed to inspect the running executable path"
        case .imageInspectionFailed:
            "failed to inspect the running executable image"
        case .missingExecutableName:
            "the running executable path has no file name"
        case .missingMachOUUID:
            "the running executable has no Mach-O UUID"
        }
    }

    package var errorDescription: String? { description }
}

package func currentProcessExecutableName() throws -> String {
#if canImport(Darwin)
    var requiredByteCount: UInt32 = 1
    var buffer = [CChar](repeating: 0, count: Int(requiredByteCount))
    var result = buffer.withUnsafeMutableBufferPointer {
        _NSGetExecutablePath($0.baseAddress, &requiredByteCount)
    }
    if result != 0 {
        guard requiredByteCount > 1 else {
            throw CurrentProcessExecutableIdentityError.executablePathInspectionFailed
        }
        buffer = [CChar](repeating: 0, count: Int(requiredByteCount))
        result = buffer.withUnsafeMutableBufferPointer {
            _NSGetExecutablePath($0.baseAddress, &requiredByteCount)
        }
    }
    guard result == 0,
          let nullIndex = buffer.firstIndex(of: 0)
    else {
        throw CurrentProcessExecutableIdentityError.executablePathInspectionFailed
    }
    let pathBytes = buffer[..<nullIndex].map { UInt8(bitPattern: $0) }
    guard let path = String(bytes: pathBytes, encoding: .utf8) else {
        throw CurrentProcessExecutableIdentityError.executablePathInspectionFailed
    }
    let executableName = URL(fileURLWithPath: path).lastPathComponent
    guard !executableName.isEmpty else {
        throw CurrentProcessExecutableIdentityError.missingExecutableName
    }
    return executableName
#else
    throw CurrentProcessExecutableIdentityError.executablePathInspectionFailed
#endif
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
