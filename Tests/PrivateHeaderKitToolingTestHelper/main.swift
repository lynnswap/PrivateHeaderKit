import Foundation
import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

private enum HelperError: Error, CustomStringConvertible {
    case invalidCommand(String)

    var description: String {
        switch self {
        case .invalidCommand(let command):
            return "invalid command: \(command)"
        }
    }
}

#if os(macOS)
private func closeStandardInput() {
    _ = close(STDIN_FILENO)
}

private func runClosedStdinCheck() throws {
    closeStandardInput()
    let result = try runStreamingSubprocess(
        ["/bin/zsh", "-lc", "cat >/dev/null; print -r -- stdin-ok"],
        streamOutput: false
    )
    guard result.status == 0, result.wasKilled == false, result.lastLines.contains("stdin-ok") else {
        fputs("status=\(result.status) killed=\(result.wasKilled) lines=\(result.lastLines)\n", stderr)
        exit(1)
    }
    print("stdin-ok")
}
#endif

do {
    let command = CommandLine.arguments.dropFirst().first ?? "stdin-closed"
    switch command {
    case "stdin-closed":
        #if os(macOS)
        try runClosedStdinCheck()
        #else
        fputs("stdin-closed helper is unsupported on this platform\n", stderr)
        exit(1)
        #endif
    default:
        throw HelperError.invalidCommand(command)
    }
} catch {
    fputs("PrivateHeaderKitToolingTestHelper: \(error)\n", stderr)
    exit(1)
}
