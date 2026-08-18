import ArgumentParser
import Foundation
import PrivateHeaderKitCore

enum PrivateHeaderKitContinuationMode: String, EnumerableFlag, Equatable, Sendable {
    case resume
    case fresh
}

extension PrivateHeaderKitGenerateCommand.Platform: ExpressibleByArgument {}

struct PrivateHeaderKitGenerationArguments: ParsableArguments {
    @Option(help: "Source platform: iOS, watchOS, or macOS.")
    var platform: PrivateHeaderKitGenerateCommand.Platform?

    @Option(name: .customLong("version"), help: "Source OS version.")
    var sourceVersion: String?

    @Option(help: "Source build identifier; required when a simulator version is ambiguous.")
    var build: String?

    @Option(name: .customLong("system-root"), help: "Runtime system root. Required for macOS.")
    var systemRoot: String?

    @Option(name: .customLong("out"), help: "Base directory for generated headers and state.")
    var outputBaseDirectory: String?

    @Option(name: .customLong("target"), help: "Target query, or 'all'.")
    var targetQuery: String?

    @Option(help: "Simulator name or UDID for iOS or watchOS generation.")
    var device: String?

    @Option(name: .customLong("sim-helper"), help: "Explicit simulator helper path.")
    var simulatorHelperPath: String?

    @Flag(exclusivity: .exclusive, help: "Continue unfinished state or start a fresh run.")
    var continuationMode: PrivateHeaderKitContinuationMode?

    var isEmpty: Bool {
        platform == nil
            && sourceVersion == nil
            && build == nil
            && systemRoot == nil
            && outputBaseDirectory == nil
            && targetQuery == nil
            && device == nil
            && simulatorHelperPath == nil
            && continuationMode == nil
    }

    func commandIfSpecified() throws -> PrivateHeaderKitGenerateCommand? {
        guard !isEmpty else {
            return nil
        }
        guard let platform else {
            throw ValidationError("Missing expected argument '--platform <platform>'")
        }
        guard let sourceVersion, !sourceVersion.isEmpty else {
            throw ValidationError("Missing expected argument '--version <version>'")
        }
        if let build, build.isEmpty {
            throw ValidationError("Argument '--build <build>' must not be empty")
        }
        guard let outputBaseDirectory, !outputBaseDirectory.isEmpty else {
            throw ValidationError("Missing expected argument '--out <out>'")
        }
        guard let targetQuery, !targetQuery.isEmpty else {
            throw ValidationError("Missing expected argument '--target <target>'")
        }
        if platform == .macOS, systemRoot?.isEmpty != false {
            throw ValidationError("Missing expected argument '--system-root <system-root>'")
        }
        if let systemRoot, systemRoot.isEmpty {
            throw ValidationError("Argument '--system-root <system-root>' must not be empty")
        }
        if let device, device.isEmpty {
            throw ValidationError("Argument '--device <device>' must not be empty")
        }
        if let simulatorHelperPath, simulatorHelperPath.isEmpty {
            throw ValidationError("Argument '--sim-helper <sim-helper>' must not be empty")
        }
        try validatePrivateHeaderKitTargetQuery(targetQuery)
        _ = try PrivateHeaderGeneration.Source(
            platform: platform.corePlatform,
            version: sourceVersion,
            build: build
        )

        return PrivateHeaderKitGenerateCommand(
            platform: platform,
            version: sourceVersion,
            build: build,
            systemRoot: systemRoot,
            outputBaseDirectory: outputBaseDirectory,
            targetQuery: targetQuery,
            continuationMode: continuationMode,
            device: device,
            simulatorHelperPath: simulatorHelperPath
        )
    }
}

struct PrivateHeaderKitArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privateheaderkit",
        abstract: "Generate private headers from an installed Apple runtime.",
        usage: "privateheaderkit [<options>]",
        subcommands: [PrivateHeaderKitGenerateAlias.self]
    )

    @OptionGroup var generation: PrivateHeaderKitGenerationArguments

    mutating func validate() throws {
        _ = try generation.commandIfSpecified()
    }
}

struct PrivateHeaderKitGenerateAlias: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate private headers.",
        shouldDisplay: false
    )

    @OptionGroup var generation: PrivateHeaderKitGenerationArguments

    mutating func validate() throws {
        _ = try generation.commandIfSpecified()
    }
}

enum PrivateHeaderKitCommand: Equatable {
    case interactiveGenerate
    case generate(PrivateHeaderKitGenerateCommand)
}

func parsePrivateHeaderKitCommand(_ args: [String]) throws -> PrivateHeaderKitCommand {
    let programName = args.first ?? "privateheaderkit"
    let invokedName = URL(fileURLWithPath: programName).lastPathComponent
    if legacyPrivateHeaderKitCommandNames.contains(invokedName) {
        throw PrivateHeaderKitCLIError.legacyCommand(invokedName)
    }
    if let firstArgument = args.dropFirst().first,
       legacyPrivateHeaderKitCommandNames.contains(firstArgument) {
        throw PrivateHeaderKitCLIError.legacyCommand(firstArgument)
    }

    var parsed = try PrivateHeaderKitArguments.parseAsRoot(Array(args.dropFirst()))
    if let root = parsed as? PrivateHeaderKitArguments {
        return try root.generation.commandIfSpecified().map(PrivateHeaderKitCommand.generate)
            ?? .interactiveGenerate
    }
    if let generate = parsed as? PrivateHeaderKitGenerateAlias {
        return try generate.generation.commandIfSpecified().map(PrivateHeaderKitCommand.generate)
            ?? .interactiveGenerate
    }
    // ArgumentParser represents both `--help` and its built-in `help` command as
    // an internal command value. Running it produces the library's typed CleanExit.
    try parsed.run()
    preconditionFailure("ArgumentParser returned an unhandled command that did not exit")
}
