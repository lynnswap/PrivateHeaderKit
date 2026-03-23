import Foundation

public enum ToolingError: Error, CustomStringConvertible {
    case message(String)
    case invalidArgument(String)
    case commandFailed(command: [String], status: Int32, stderr: String)
    case processLaunchFailed(command: [String], underlying: String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        case .invalidArgument(let text):
            return "invalid argument: \(text)"
        case .commandFailed(let command, let status, let stderr):
            let cmd = command.joined(separator: " ")
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "command failed (status=\(status)): \(cmd)"
            }
            return "command failed (status=\(status)): \(cmd)\n\(trimmed)"
        case .processLaunchFailed(let command, let underlying):
            let cmd = command.joined(separator: " ")
            let trimmed = underlying.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "failed to launch process: \(cmd)"
            }
            return "failed to launch process: \(cmd)\n\(trimmed)"
        case .unsupported(let text):
            return "unsupported: \(text)"
        }
    }
}
