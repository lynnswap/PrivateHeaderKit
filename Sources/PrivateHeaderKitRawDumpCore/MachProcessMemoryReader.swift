import Foundation

#if canImport(Darwin)
import Darwin

final class MachProcessMemoryReader: ProcessMemoryReading {
    private var task: mach_port_t

    init(processIdentifier: Int32) throws {
        guard processIdentifier > 0 else {
            throw ProcessImageRecoveryError.invalidMetadata("process identifier must be positive")
        }
        var task = mach_port_t(MACH_PORT_NULL)
        let result = task_for_pid(mach_task_self_, processIdentifier, &task)
        guard result == KERN_SUCCESS else {
            throw ProcessImageMachError(operation: "task_for_pid", code: result)
        }
        self.task = task
    }

    func close() throws {
        guard task != MACH_PORT_NULL else { return }
        let result = mach_port_deallocate(mach_task_self_, task)
        guard result == KERN_SUCCESS else {
            throw ProcessImageMachError(operation: "mach_port_deallocate", code: result)
        }
        task = mach_port_t(MACH_PORT_NULL)
    }

    func dyldInformation() throws -> ProcessDyldInformation {
        var information = task_dyld_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_dyld_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_DYLD_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw ProcessImageMachError(operation: "task_info(TASK_DYLD_INFO)", code: result)
        }
        return .init(address: information.all_image_info_addr, size: information.all_image_info_size,
                     format: information.all_image_info_format)
    }

    func read(address: UInt64, byteCount: Int) throws -> Data {
        guard byteCount >= 0, let nativeAddress = vm_address_t(exactly: address),
              let nativeSize = vm_size_t(exactly: byteCount),
              nativeSize <= vm_address_t.max - nativeAddress else {
            throw ProcessImageRecoveryError.invalidMetadata("process memory range exceeds the address space")
        }
        guard byteCount > 0 else { return Data() }
        var bytes = Data(count: byteCount)
        var actual = vm_size_t(0)
        let result = bytes.withUnsafeMutableBytes { buffer in
            vm_read_overwrite(task, nativeAddress, nativeSize,
                              vm_address_t(UInt(bitPattern: buffer.baseAddress!)), &actual)
        }
        guard result == KERN_SUCCESS else {
            throw ProcessImageMachError(operation: "vm_read_overwrite", code: result,
                                        address: address, byteCount: byteCount)
        }
        guard actual == nativeSize else {
            throw ProcessImageRecoveryError.shortMemoryRead(expected: byteCount, actual: Int(actual))
        }
        return bytes
    }
}

struct ProcessImageMachError: Error, CustomStringConvertible {
    let operation: String
    let code: kern_return_t
    var address: UInt64? = nil
    var byteCount: Int? = nil

    var description: String {
        let message = mach_error_string(code).map { String(cString: $0) } ?? "unknown Mach error"
        let range = address.map { " at address \($0) for \(byteCount ?? 0) bytes" } ?? ""
        return "\(operation) failed\(range): \(message) (\(code))"
    }
}
#endif
