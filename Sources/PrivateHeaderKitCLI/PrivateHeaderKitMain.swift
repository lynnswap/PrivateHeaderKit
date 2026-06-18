import Foundation
import HeaderDumpCore
import PrivateHeaderKitCore
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

struct PrivateHeaderKitGenerationRequest: Sendable {
    let source: PrivateHeaderGeneration.Source
    let output: PrivateHeaderGeneration.Output
    let options: PrivateHeaderGeneration.Options

    var sourceDisplayName: String {
        source.label.displayName
    }

    var sourceDirectoryName: String {
        source.label.directoryName
    }

    var artifactBaseDirectory: URL {
        output.artifactBaseDirectory
    }

    var stateBaseDirectory: URL {
        output.stateBaseDirectory
    }

    var systemRoot: URL? {
        options.systemRoot
    }

    var targetQuery: String? {
        guard case .query(let query) = options.targetRequest else {
            return nil
        }
        return query
    }

    var resumeRequested: Bool? {
        guard case .requireExplicitResume(let resumeRequested) = options.resumeBehavior else {
            return nil
        }
        return resumeRequested
    }

    var hostHelperURL: URL? {
        options.helperURLs?.host
    }

    var simulatorHelperURL: URL? {
        options.helperURLs?.simulator
    }

    var usesHostExecution: Bool {
        guard case .host = options.executionMode else {
            return false
        }
        return true
    }

    var usesSharedCache: Bool {
        options.rawDumpingOptions.useSharedCache
    }

    var prefersRuntimeMetadata: Bool {
        options.rawDumpingOptions.preferRuntimeMetadata
    }
}

struct PrivateHeaderKitGenerationSummary: Equatable, Sendable {
    let sourceDisplayName: String
    let artifactDirectory: URL
    let manifestURL: URL
    let runRecordURL: URL
    let runID: String
    let generatedTargetCount: Int
    let skippedTargetCount: Int?

    init(
        sourceDisplayName: String,
        artifactDirectory: URL,
        manifestURL: URL,
        runRecordURL: URL,
        runID: String,
        generatedTargetCount: Int,
        skippedTargetCount: Int? = nil
    ) {
        self.sourceDisplayName = sourceDisplayName
        self.artifactDirectory = artifactDirectory
        self.manifestURL = manifestURL
        self.runRecordURL = runRecordURL
        self.runID = runID
        self.generatedTargetCount = generatedTargetCount
        self.skippedTargetCount = skippedTargetCount
    }

    init(result: PrivateHeaderGeneration.Result) {
        self.init(
            sourceDisplayName: result.plan.source.label.displayName,
            artifactDirectory: result.artifactDirectory,
            manifestURL: result.manifestURL,
            runRecordURL: result.runRecordURL,
            runID: result.runID,
            generatedTargetCount: result.generatedTargets.count,
            skippedTargetCount: Self.skippedTargetCount(from: result.runRecordURL)
        )
    }

    private static func skippedTargetCount(from runRecordURL: URL) -> Int? {
        guard
            let data = try? Data(contentsOf: runRecordURL),
            let runRecord = try? JSONDecoder().decode(TargetResultsRecord.self, from: data)
        else {
            return nil
        }
        return runRecord.targetResults.filter { $0.status == "skipped" }.count
    }

    private struct TargetResultsRecord: Decodable {
        let targetResults: [TargetRecord]
    }

    private struct TargetRecord: Decodable {
        let status: String
    }
}

typealias PrivateHeaderKitGenerationRunner = (
    PrivateHeaderKitGenerationRequest
) async throws -> PrivateHeaderKitGenerationSummary

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
    currentExecutableURL: URL? = Bundle.main.executableURL,
    generationRunner: @escaping PrivateHeaderKitGenerationRunner = runPrivateHeaderGeneration,
    outputLogger: (String) -> Void = logCLIOutput,
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
            return await runPrivateHeaderKitGenerateCommand(
                command,
                invokedProgramName: args.first ?? "privateheaderkit",
                currentExecutableURL: currentExecutableURL,
                generationRunner: generationRunner,
                outputLogger: outputLogger,
                errorLogger: errorLogger
            )
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

private func runPrivateHeaderKitGenerateCommand(
    _ command: PrivateHeaderKitGenerateCommand,
    invokedProgramName: String,
    currentExecutableURL: URL?,
    generationRunner: PrivateHeaderKitGenerationRunner,
    outputLogger: (String) -> Void,
    errorLogger: (String) -> Void
) async -> Int32 {
    do {
        let request = try makePrivateHeaderGenerationRequest(
            from: command,
            helperExecutableURL: privateHeaderKitExecutableURL(
                currentExecutableURL: currentExecutableURL,
                fallbackProgramName: invokedProgramName
            )
        )
        let summary = try await generationRunner(request)
        logPrivateHeaderGenerationSuccess(summary, outputLogger: outputLogger)
        return 0
    } catch let error as PrivateHeaderGeneration.GenerationError {
        errorLogger("error: \(error.description)")
        if case .resumeRequired = error {
            errorLogger("rerun with `--resume` to continue the unfinished generation state")
        }
        return 2
    } catch {
        errorLogger("error: \(error)")
        return 2
    }
}

private func runPrivateHeaderGeneration(
    request: PrivateHeaderKitGenerationRequest
) async throws -> PrivateHeaderKitGenerationSummary {
    let result = try await PrivateHeaderGeneration.generatePrivateHeaders(
        source: request.source,
        output: request.output,
        options: request.options
    )
    return PrivateHeaderKitGenerationSummary(result: result)
}

private func makePrivateHeaderGenerationRequest(
    from command: PrivateHeaderKitGenerateCommand,
    helperExecutableURL: URL
) throws -> PrivateHeaderKitGenerationRequest {
    let source = try PrivateHeaderGeneration.Source(
        platform: command.platform.corePlatform,
        version: command.version,
        build: command.build
    )
    let outputBaseDirectory = URL(
        fileURLWithPath: command.outputBaseDirectory,
        isDirectory: true
    )
    let output = PrivateHeaderGeneration.Output(baseDirectory: outputBaseDirectory)
    let helperURLs = PrivateHeaderGeneration.RawDumping.HelperURLs(
        host: helperExecutableURL,
        simulator: helperExecutableURL
    )
    let options = PrivateHeaderGeneration.Options(
        targetRequest: .query(command.targetQuery),
        systemRoot: URL(fileURLWithPath: command.systemRoot, isDirectory: true),
        helperURLs: helperURLs,
        executionMode: .host,
        rawDumpingOptions: PrivateHeaderGeneration.RawDumping.Options(
            useSharedCache: true,
            preferRuntimeMetadata: true
        ),
        resumeBehavior: .requireExplicitResume(resumeRequested: command.resume),
        outputBaseDirectory: outputBaseDirectory
    )

    return PrivateHeaderKitGenerationRequest(
        source: source,
        output: output,
        options: options
    )
}

private func privateHeaderKitExecutableURL(
    currentExecutableURL: URL?,
    fallbackProgramName: String
) -> URL {
    if let currentExecutableURL {
        return currentExecutableURL
    }
    return URL(fileURLWithPath: fallbackProgramName, isDirectory: false)
}

private func logPrivateHeaderGenerationSuccess(
    _ summary: PrivateHeaderKitGenerationSummary,
    outputLogger: (String) -> Void
) {
    outputLogger("private header generation completed")
    outputLogger("source: \(summary.sourceDisplayName)")
    outputLogger("artifact directory: \(summary.artifactDirectory.path)")
    outputLogger("manifest path: \(summary.manifestURL.path)")
    outputLogger("run record path: \(summary.runRecordURL.path)")
    outputLogger("run ID: \(summary.runID)")
    if let skippedTargetCount = summary.skippedTargetCount {
        outputLogger("targets: generated \(summary.generatedTargetCount), skipped \(skippedTargetCount)")
    } else {
        outputLogger("targets: generated \(summary.generatedTargetCount)")
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

private extension PrivateHeaderKitGenerateCommand.Platform {
    var corePlatform: PrivateHeaderGeneration.Source.Platform {
        switch self {
        case .iOS:
            return .iOS
        case .macOS:
            return .macOS
        }
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

private func logCLIOutput(_ message: String) {
    print(message)
}
