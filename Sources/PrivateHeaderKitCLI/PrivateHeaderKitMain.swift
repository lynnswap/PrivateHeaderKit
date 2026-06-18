import Foundation
import PrivateHeaderKitInstall

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PrivateHeaderKitMain {
    static func main() {
        exit(runPrivateHeaderKitCommand(CommandLine.arguments))
    }
}

enum PrivateHeaderKitCommand: Equatable {
    case help
    case install([String])
    case generationUnavailable([String])
}

enum PrivateHeaderKitCLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case legacyCommand(String)

    var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .legacyCommand(let command):
            return "\(command) is no longer a user-facing command; use privateheaderkit instead"
        }
    }
}

func runPrivateHeaderKitCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Int32 {
    do {
        switch try parsePrivateHeaderKitCommand(args) {
        case .help:
            printPrivateHeaderKitUsage()
            return 0
        case .install(let installArgs):
            return runInstallCommand(installArgs, environment: environment)
        case .generationUnavailable:
            logCLIError("private header generation is being wired into the rewrite command surface")
            logCLIError("run `privateheaderkit --help` for available commands")
            return 2
        }
    } catch let error as PrivateHeaderKitCLIError {
        logCLIError("error: \(error.description)")
        logCLIError("run `privateheaderkit --help` for usage")
        return 1
    } catch {
        logCLIError("error: \(error)")
        logCLIError("run `privateheaderkit --help` for usage")
        return 1
    }
}

func parsePrivateHeaderKitCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    let programName = args.first ?? "privateheaderkit"
    let remaining = Array(args.dropFirst())

    guard let command = remaining.first else {
        return .generationUnavailable([])
    }

    switch command {
    case "-h", "--help", "help":
        return .help
    case "install":
        let installArgs = ["\(programName) install"] + Array(remaining.dropFirst())
        return .install(installArgs)
    case "generate":
        return .generationUnavailable(Array(remaining.dropFirst()))
    case "privateheaderkit-dump", "headerdump", "headerdump-sim":
        throw PrivateHeaderKitCLIError.legacyCommand(command)
    default:
        throw PrivateHeaderKitCLIError.unknownCommand(command)
    }
}

func printPrivateHeaderKitUsage() {
    let text = """
    Usage:
      privateheaderkit [command] [options]

    Commands:
      install    Install the privateheaderkit command
      generate   Generate private headers (rewrite execution integration pending)

    Options:
      -h, --help  Show this help

    Examples:
      privateheaderkit install --bindir "$HOME/bin"
    """
    print(text)
}

private func logCLIError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}
