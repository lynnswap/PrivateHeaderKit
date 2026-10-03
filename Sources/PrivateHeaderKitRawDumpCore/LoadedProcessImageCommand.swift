import Foundation
import PrivateHeaderKitHelperProtocol

#if canImport(Darwin)
package enum LoadedProcessImageCommand {
    package static func run(arguments: [String]) throws -> Data {
        guard let command = arguments.first,
              command == PrivateHeaderKitHelperCommand.processImages.rawValue
                || command == PrivateHeaderKitHelperCommand.recoverProcessImage.rawValue else {
            throw CommandError.invalidArguments
        }
        let options = try Options(arguments: Array(arguments.dropFirst()))
        guard let pidString = options.values["--pid"], let pid = Int32(pidString), pid > 0 else {
            throw CommandError.invalidArguments
        }
        let request: Request
        if command == PrivateHeaderKitHelperCommand.processImages.rawValue {
            guard Set(options.values.keys) == ["--pid"] else {
                throw CommandError.invalidArguments
            }
            request = .inventory
        } else {
            guard Set(options.values.keys) == ["--pid", "--image-address", "--expected-uuid", "--output"],
                  let addressString = options.values["--image-address"], let address = UInt64(addressString),
                  let uuidString = options.values["--expected-uuid"], let uuid = UUID(uuidString: uuidString),
                  let output = options.values["--output"], !output.isEmpty else {
                throw CommandError.invalidArguments
            }
            request = .recover(address: address, uuid: uuid, output: URL(filePath: output))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try LoadedProcessImages.withProcess(processIdentifier: pid) { process in
            switch request {
            case .inventory:
                return try encoder.encode(process.images())
            case .recover(let address, let uuid, let output):
                let inventory = try process.images()
                guard let image = inventory.images.first(where: { $0.loadAddress == address && $0.uuid == uuid }) else {
                    if let failure = inventory.failures.first(where: { $0.loadAddress == address }) {
                        throw CommandError.imageInspectionFailed(failure.error)
                    }
                    throw ProcessImageRecoveryError.imageIdentityMismatch
                }
                return try encoder.encode(process.recover(image: image, to: output))
            }
        }
    }

    private enum Request {
        case inventory
        case recover(address: UInt64, uuid: UUID, output: URL)
    }

    private struct Options {
        var values: [String: String] = [:]

        init(arguments: [String]) throws {
            guard arguments.count.isMultiple(of: 2) else { throw CommandError.invalidArguments }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let name = arguments[index]
                guard values[name] == nil else { throw CommandError.invalidArguments }
                values[name] = arguments[index + 1]
            }
        }
    }

    enum CommandError: Error, Equatable, CustomStringConvertible {
        case invalidArguments
        case imageInspectionFailed(String)

        var description: String {
            switch self {
            case .invalidArguments:
                "expected __process-images --pid <pid> or __recover-process-image --pid <pid> --image-address <decimal-address> --expected-uuid <uuid> --output <file>"
            case .imageInspectionFailed(let error): "selected process image could not be inspected: \(error)"
            }
        }
    }
}
#endif
