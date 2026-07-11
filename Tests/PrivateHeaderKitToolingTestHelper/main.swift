import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

private enum HelperError: Error, CustomStringConvertible {
    case invalidCommand(String)
    case posix(operation: String, code: Int32)

    var description: String {
        switch self {
        case .invalidCommand(let command):
            return "invalid command: \(command)"
        case .posix(let operation, let code):
            return "\(operation) failed (errno \(code))"
        }
    }
}

@main
private struct PrivateHeaderKitToolingTestHelper {
    static func main() async {
        do {
            let command = CommandLine.arguments.dropFirst().first ?? "stdin-closed"
            switch command {
            case "stdin-closed":
#if os(macOS)
                try await runClosedStdinCheck()
#else
                throw HelperError.invalidCommand(command)
#endif
            case "large-capture":
                FileHandle.standardOutput.write(Data(repeating: UInt8(ascii: "x"), count: 256 * 1024))
            case "chunked-output":
                try writeChunkedOutput()
            case "process-group":
#if os(macOS)
                let arguments = Array(CommandLine.arguments.dropFirst(2))
                guard arguments.count == 2 else {
                    throw HelperError.invalidCommand(command)
                }
                try runProcessGroup(
                    parentLockPath: arguments[0],
                    childLockPath: arguments[1]
                )
#else
                throw HelperError.invalidCommand(command)
#endif
            case "process-group-child":
#if os(macOS)
                let arguments = Array(CommandLine.arguments.dropFirst(2))
                guard arguments.count == 1 else {
                    throw HelperError.invalidCommand(command)
                }
                try runProcessGroupChild(lockPath: arguments[0])
#else
                throw HelperError.invalidCommand(command)
#endif
            default:
                throw HelperError.invalidCommand(command)
            }
        } catch {
            FileHandle.standardError.write(
                Data("PrivateHeaderKitToolingTestHelper: \(error)\n".utf8)
            )
            exit(1)
        }
    }

    private static func writeChunkedOutput() throws {
        let prefix = (1...9).map { "line-\($0)\n" }.joined() + "emoji:"
        try writeAll(Array(prefix.utf8), to: STDOUT_FILENO)
        try writeAll([0xF0, 0x9F], to: STDOUT_FILENO)
        try writeAll([0x98, 0x80], to: STDOUT_FILENO)
        try writeAll(Array("\nline-10\n".utf8), to: STDOUT_FILENO)
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var writtenCount = 0
        while writtenCount < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    preconditionFailure("nonempty byte buffer has no base address")
                }
                return write(
                    descriptor,
                    baseAddress.advanced(by: writtenCount),
                    buffer.count - writtenCount
                )
            }
            guard written > 0 else {
                throw HelperError.posix(operation: "write", code: errno)
            }
            writtenCount += written
        }
    }

#if os(macOS)
    private static func runClosedStdinCheck() async throws {
        _ = close(STDIN_FILENO)
        let result = try await ProcessRunner().runStreaming(
            ["/bin/zsh", "-lc", "cat >/dev/null; print -r -- stdin-ok"],
            env: nil,
            cwd: nil
        )
        guard result.status == 0,
              !result.wasKilled,
              result.lastLines.contains("stdin-ok")
        else {
            throw ToolingError.message(
                "status=\(result.status) killed=\(result.wasKilled) lines=\(result.lastLines)"
            )
        }
        print("stdin-ok")
    }

    private static func runProcessGroup(
        parentLockPath: String,
        childLockPath: String
    ) throws -> Never {
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        let parentLock = parentLockPath.withCString {
            open($0, O_CREAT | O_RDWR, permissions)
        }
        guard parentLock >= 0 else {
            throw HelperError.posix(operation: "open parent lock", code: errno)
        }
        let childLock = childLockPath.withCString {
            open($0, O_CREAT | O_RDWR, permissions)
        }
        guard childLock >= 0 else {
            let code = errno
            _ = close(parentLock)
            throw HelperError.posix(operation: "open child lock", code: code)
        }
        guard flock(parentLock, LOCK_EX) == 0 else {
            let code = errno
            _ = close(parentLock)
            _ = close(childLock)
            throw HelperError.posix(operation: "lock parent", code: code)
        }

        _ = close(childLock)
        let executable = CommandLine.arguments[0]
        let argumentValues = [executable, "process-group-child", childLockPath]
        var argumentPointers = argumentValues.map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil {
                free(pointer)
            }
        }
        var childPID: pid_t = 0
        let spawnStatus = executable.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { arguments in
                posix_spawn(
                    &childPID,
                    executablePointer,
                    nil,
                    nil,
                    arguments.baseAddress,
                    environ
                )
            }
        }
        guard spawnStatus == 0 else {
            throw HelperError.posix(operation: "posix_spawn", code: spawnStatus)
        }
        while true { _ = pause() }
    }

    private static func runProcessGroupChild(lockPath: String) throws -> Never {
        let permissions = mode_t(S_IRUSR | S_IWUSR)
        let lockDescriptor = lockPath.withCString {
            open($0, O_CREAT | O_RDWR, permissions)
        }
        guard lockDescriptor >= 0 else {
            throw HelperError.posix(operation: "open child lock", code: errno)
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw HelperError.posix(operation: "lock child", code: errno)
        }
        try writeAll(Array("READY\n".utf8), to: STDOUT_FILENO)
        while true { _ = pause() }
    }
#endif
}
