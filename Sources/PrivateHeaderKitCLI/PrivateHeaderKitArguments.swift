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

    @Option(name: .customLong("out"), help: "Base directory for generated headers and state. Use alone to start the wizard.")
    var outputBaseDirectory: String?

    @Option(name: .customLong("target"), help: "Target query, or 'all'.")
    var targetQuery: String?

    @Option(help: "Simulator name or UDID for iOS or watchOS generation.")
    var device: String?

    @Option(name: .customLong("sim-helper"), help: "Explicit simulator helper path.")
    var simulatorHelperPath: String?

    @Flag(exclusivity: .exclusive, help: "Continue or restart all-target generation. --fresh also permits legacy migration.")
    var continuationMode: PrivateHeaderKitContinuationMode?

    var usesInteractiveSelection: Bool {
        platform == nil
            && sourceVersion == nil
            && build == nil
            && systemRoot == nil
            && targetQuery == nil
            && device == nil
            && simulatorHelperPath == nil
            && continuationMode == nil
    }

    func command() throws -> PrivateHeaderKitCommand {
        if let outputBaseDirectory, outputBaseDirectory.isEmpty {
            throw ValidationError("Argument '--out <out>' must not be empty")
        }
        if usesInteractiveSelection {
            return .interactiveGenerate(outputBaseDirectory: outputBaseDirectory)
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
        guard let outputBaseDirectory else {
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
        if let device, device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Argument '--device <device>' must not be empty")
        }
        if let simulatorHelperPath, simulatorHelperPath.isEmpty {
            throw ValidationError("Argument '--sim-helper <sim-helper>' must not be empty")
        }
        try validatePrivateHeaderKitTargetQuery(targetQuery)
        try PrivateHeaderGeneration.Source.validateIdentity(
            platform: platform.corePlatform,
            version: sourceVersion,
            build: build
        )

        return .generate(PrivateHeaderKitGenerateCommand(
            platform: platform,
            version: sourceVersion,
            build: build,
            systemRoot: systemRoot,
            outputBaseDirectory: outputBaseDirectory,
            targetQuery: targetQuery,
            continuationMode: continuationMode,
            device: device,
            simulatorHelperPath: simulatorHelperPath
        ))
    }
}

struct PrivateHeaderKitArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privateheaderkit",
        abstract: "Generate private headers and searchable symbols from an installed Apple runtime.",
        usage: "privateheaderkit [<options>]\n       privateheaderkit <subcommand> [<options>]",
        subcommands: [PrivateHeaderKitGenerateAlias.self, PrivateHeaderKitSearchArguments.self, PrivateHeaderKitDecompileArguments.self]
    )

    @OptionGroup var generation: PrivateHeaderKitGenerationArguments

    mutating func validate() throws {
        _ = try generation.command()
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
        _ = try generation.command()
    }
}

enum PrivateHeaderKitCommand: Equatable {
    case interactiveGenerate(outputBaseDirectory: String?)
    case generate(PrivateHeaderKitGenerateCommand)
    case decompile(PrivateHeaderKitDecompileCommand)
    case search(PrivateHeaderKitSearchCommand)
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
    if let decompile = parsed as? PrivateHeaderKitDecompileArguments {
        return .decompile(try decompile.command())
    }
    if let search = parsed as? PrivateHeaderKitSearchArguments {
        return .search(search.command)
    }
    if let root = parsed as? PrivateHeaderKitArguments {
        return try root.generation.command()
    }
    if let generate = parsed as? PrivateHeaderKitGenerateAlias {
        return try generate.generation.command()
    }
    // ArgumentParser represents both `--help` and its built-in `help` command as
    // an internal command value. Running it produces the library's typed CleanExit.
    try parsed.run()
    preconditionFailure("ArgumentParser returned an unhandled command that did not exit")
}
