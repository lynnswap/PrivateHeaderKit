import Foundation
import HeaderDumpCore
import PrivateHeaderKitInstall

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct PrivateHeaderKitMain {
    static func main() async {
        exit(await runPrivateHeaderKitCommand(CommandLine.arguments))
    }
}

enum PrivateHeaderKitCommand: Equatable {
    case help
    case generateHelp
    case install([String])
    case generate(PrivateHeaderKitGenerateCommand)
    case rawDump([String])
}

struct PrivateHeaderKitGenerateCommand: Equatable, Sendable {
    enum Platform: String, Sendable {
        case iOS = "iOS"
        case macOS = "macOS"
    }

    let platform: Platform
    let version: String
    let build: String?
    let systemRoot: String
    let outputBaseDirectory: String
    let targetQuery: String
    let resume: Bool

    var sourceDisplayName: String {
        sourceLabel(separator: " ")
    }

    var sourceDirectoryName: String {
        sourceLabel(separator: "")
    }

    var artifactDirectory: URL {
        URL(fileURLWithPath: outputBaseDirectory, isDirectory: true)
            .appendingPathComponent(sourceDirectoryName, isDirectory: true)
    }

    var stateDirectory: URL {
        URL(fileURLWithPath: outputBaseDirectory, isDirectory: true)
            .appendingPathComponent(".state", isDirectory: true)
            .appendingPathComponent(sourceDirectoryName, isDirectory: true)
    }

    private func sourceLabel(separator: String) -> String {
        let baseName = "\(platform.rawValue)\(separator)\(version)"
        if let build {
            let buildSeparator = separator.isEmpty ? "" : " "
            return "\(baseName)\(buildSeparator)(\(build))"
        }
        return baseName
    }
}

private let legacyPublicCommandNames: Set<String> = [
    "privateheaderkit-dump",
    "headerdump",
    "headerdump-sim",
]

enum PrivateHeaderKitCLIError: Error, Equatable, CustomStringConvertible {
    case unknownCommand(String)
    case legacyCommand(String)
    case unknownOption(String)
    case duplicateOption(String)
    case missingRequiredOption(String)
    case missingValue(String)
    case unexpectedValue(String)
    case unexpectedArgument(String)
    case invalidPlatform(String)
    case emptyOptionValue(String)
    case invalidSourceComponent(option: String, value: String)
    case invalidTargetQuery(String)

    var description: String {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .legacyCommand(let command):
            return "\(command) is no longer a user-facing command; use privateheaderkit instead"
        case .unknownOption(let option):
            return "unknown option: \(option)"
        case .duplicateOption(let option):
            return "duplicate option: \(option)"
        case .missingRequiredOption(let option):
            return "missing required option: \(option)"
        case .missingValue(let option):
            return "missing value for option: \(option)"
        case .unexpectedValue(let option):
            return "unexpected value for flag: \(option)"
        case .unexpectedArgument(let argument):
            return "unexpected argument: \(argument)"
        case .invalidPlatform(let value):
            return "invalid platform: \(value); expected iOS or macOS"
        case .emptyOptionValue(let option):
            return "empty value for option: \(option)"
        case .invalidSourceComponent(let option, let value):
            return "\(option) is not safe as a source label path component: \(value)"
        case .invalidTargetQuery(let value):
            return "target query must be a comma-separated list without empty entries: \(value)"
        }
    }
}

func runPrivateHeaderKitCommand(
    _ args: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    errorLogger: (String) -> Void = logCLIError
) async -> Int32 {
    do {
        switch try parsePrivateHeaderKitCommand(args) {
        case .help:
            printPrivateHeaderKitUsage()
            return 0
        case .generateHelp:
            printPrivateHeaderKitGenerateUsage()
            return 0
        case .install(let installArgs):
            return runInstallCommand(installArgs, environment: environment)
        case .generate(let command):
            errorLogger("private header generation is parsed but not wired to the Core executor yet")
            errorLogger("source: \(command.sourceDisplayName)")
            errorLogger("artifact directory: \(command.artifactDirectory.path)")
            errorLogger("state directory: \(command.stateDirectory.path)")
            errorLogger("target query: \(command.targetQuery)")
            if command.resume {
                errorLogger("resume: requested")
            }
            return 2
        case .rawDump(let rawDumpArgs):
            await HeaderDumpCore.HeaderDumpCLI.main(arguments: rawDumpArgs)
            return 0
        }
    } catch let error as PrivateHeaderKitCLIError {
        errorLogger("error: \(error.description)")
        errorLogger("run `privateheaderkit --help` for usage")
        return 1
    } catch {
        errorLogger("error: \(error)")
        errorLogger("run `privateheaderkit --help` for usage")
        return 1
    }
}

func parsePrivateHeaderKitCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    let programName = args.first ?? "privateheaderkit"
    let remaining = Array(args.dropFirst())

    let invokedName = URL(fileURLWithPath: programName).lastPathComponent
    if legacyPublicCommandNames.contains(invokedName) {
        throw PrivateHeaderKitCLIError.legacyCommand(invokedName)
    }

    guard let command = remaining.first else {
        return .help
    }

    switch command {
    case "-h", "--help", "help":
        return .help
    case "install":
        let installArgs = ["\(programName) install"] + Array(remaining.dropFirst())
        return .install(installArgs)
    case "generate":
        return try parsePrivateHeaderKitGenerateCommand(Array(remaining.dropFirst()))
    case "__raw-dump":
        return .rawDump(Array(remaining.dropFirst()))
    case let command where legacyPublicCommandNames.contains(command):
        throw PrivateHeaderKitCLIError.legacyCommand(command)
    default:
        throw PrivateHeaderKitCLIError.unknownCommand(command)
    }
}

private func parsePrivateHeaderKitGenerateCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    if args == ["-h"] || args == ["--help"] || args == ["help"] {
        return .generateHelp
    }

    var platform: PrivateHeaderKitGenerateCommand.Platform?
    var version: String?
    var build: String?
    var systemRoot: String?
    var outputBaseDirectory: String?
    var targetQuery: String?
    var resume = false
    var seenOptions: Set<String> = []

    var index = 0
    while index < args.count {
        let argument = args[index]

        if argument == "-h" || argument == "--help" {
            return .generateHelp
        }

        guard argument.hasPrefix("--") else {
            throw PrivateHeaderKitCLIError.unexpectedArgument(argument)
        }

        let parsedOption = splitLongOption(argument)
        let option = parsedOption.name
        let inlineValue = parsedOption.value

        switch option {
        case "--platform":
            try markOptionSeen(option, in: &seenOptions)
            let value = try readOptionValue(
                option: option,
                inlineValue: inlineValue,
                args: args,
                index: &index
            )
            guard let parsedPlatform = PrivateHeaderKitGenerateCommand.Platform(rawValue: value) else {
                throw PrivateHeaderKitCLIError.invalidPlatform(value)
            }
            platform = parsedPlatform
        case "--version":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateSourcePathComponent(value, option: option)
            version = value
        case "--build":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateSourcePathComponent(value, option: option)
            build = value
        case "--system-root":
            try markOptionSeen(option, in: &seenOptions)
            systemRoot = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--out":
            try markOptionSeen(option, in: &seenOptions)
            outputBaseDirectory = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
        case "--target":
            try markOptionSeen(option, in: &seenOptions)
            let value = try nonEmptyOptionValue(
                try readOptionValue(option: option, inlineValue: inlineValue, args: args, index: &index),
                option: option
            )
            try validateTargetQuery(value)
            targetQuery = value
        case "--resume":
            try markOptionSeen(option, in: &seenOptions)
            if inlineValue != nil {
                throw PrivateHeaderKitCLIError.unexpectedValue(option)
            }
            resume = true
            index += 1
        default:
            throw PrivateHeaderKitCLIError.unknownOption(option)
        }
    }

    guard let platform else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--platform")
    }
    guard let version else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--version")
    }
    guard let systemRoot else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--system-root")
    }
    guard let outputBaseDirectory else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--out")
    }
    guard let targetQuery else {
        throw PrivateHeaderKitCLIError.missingRequiredOption("--target")
    }

    return .generate(
        PrivateHeaderKitGenerateCommand(
            platform: platform,
            version: version,
            build: build,
            systemRoot: systemRoot,
            outputBaseDirectory: outputBaseDirectory,
            targetQuery: targetQuery,
            resume: resume
        )
    )
}

private func splitLongOption(_ argument: String) -> (name: String, value: String?) {
    guard let separator = argument.firstIndex(of: "=") else {
        return (argument, nil)
    }
    let name = String(argument[..<separator])
    let value = String(argument[argument.index(after: separator)...])
    return (name, value)
}

private func markOptionSeen(_ option: String, in seenOptions: inout Set<String>) throws {
    guard seenOptions.insert(option).inserted else {
        throw PrivateHeaderKitCLIError.duplicateOption(option)
    }
}

private func readOptionValue(
    option: String,
    inlineValue: String?,
    args: [String],
    index: inout Int
) throws -> String {
    if let inlineValue {
        index += 1
        return inlineValue
    }

    let valueIndex = index + 1
    guard valueIndex < args.count else {
        throw PrivateHeaderKitCLIError.missingValue(option)
    }
    guard !args[valueIndex].hasPrefix("--") else {
        throw PrivateHeaderKitCLIError.missingValue(option)
    }
    index += 2
    return args[valueIndex]
}

private func nonEmptyOptionValue(_ value: String, option: String) throws -> String {
    guard !value.isEmpty else {
        throw PrivateHeaderKitCLIError.emptyOptionValue(option)
    }
    return value
}

private func validateSourcePathComponent(_ value: String, option: String) throws {
    guard value != ".", value != "..", !value.contains("/"), !value.contains("\0") else {
        throw PrivateHeaderKitCLIError.invalidSourceComponent(option: option, value: value)
    }
}

private func validateTargetQuery(_ value: String) throws {
    let entries = value.split(separator: ",", omittingEmptySubsequences: false)
    let hasEmptyEntry = entries.contains { entry in
        String(entry).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !hasEmptyEntry else {
        throw PrivateHeaderKitCLIError.invalidTargetQuery(value)
    }
}

func printPrivateHeaderKitUsage() {
    print(privateHeaderKitUsageText())
}

func printPrivateHeaderKitGenerateUsage() {
    print(privateHeaderKitGenerateUsageText())
}

func privateHeaderKitUsageText() -> String {
    """
    Usage:
      privateheaderkit [command] [options]

    Commands:
      install    Install the privateheaderkit command
      generate   Generate private headers from an explicit source and target query

    Options:
      -h, --help  Show this help

    Examples:
      privateheaderkit install --bindir "$HOME/bin"
      privateheaderkit generate --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
    """
}

func privateHeaderKitGenerateUsageText() -> String {
    """
    Usage:
      privateheaderkit generate --platform <iOS|macOS> --version <version> [--build <build>] --system-root <path> --out <path> --target <query> [--resume]

    Required Options:
      --platform <iOS|macOS>  Source platform
      --version <version>     Source OS version
      --system-root <path>    Mounted system root to scan
      --out <path>            Output base directory
      --target <query>        Comma-separated target query, for example SwiftUI,UIKit

    Optional Options:
      --build <build>         Source build train for labels and state keys
      --resume                Resume the matching explicit source/output/target run
      -h, --help              Show this help

    Output:
      Headers: <out>/<platform><version>(<build>)/
      State:   <out>/.state/<platform><version>(<build>)/

    Examples:
      privateheaderkit generate --platform iOS --version 27.0 --build 24A5355q --system-root /path/to/RuntimeRoot --out "$HOME/PrivateHeaderKit" --target "SwiftUI,UIKit"
      privateheaderkit generate --platform macOS --version 16.0 --system-root / --out "$HOME/PrivateHeaderKit" --target "AppKit,Foundation" --resume
    """
}

private func logCLIError(_ message: String) {
    let data = Data((message + "\n").utf8)
    FileHandle.standardError.write(data)
}
