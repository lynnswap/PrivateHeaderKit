import ArgumentParser
import Foundation
import PrivateHeaderKitCore
import PrivateHeaderKitTooling

let legacyPrivateHeaderKitCommandNames: Set<String> = [
    "privateheaderkit-dump",
    "headerdump",
    "headerdump-sim",
]

enum PrivateHeaderKitCLIError: Error, Equatable, CustomStringConvertible {
    case legacyCommand(String)
    case missingSimulatorResolution

    var description: String {
        switch self {
        case .legacyCommand(let command):
            "\(command) is no longer a user-facing command; use privateheaderkit instead"
        case .missingSimulatorResolution:
            "simulator generation requires a resolved runtime and device"
        }
    }
}

typealias PrivateHeaderKitOutputLogger = @Sendable (String) -> Void

/// The `privateheaderkit` command line: parses the arguments and runs the command they select.
///
/// The properties are everything a command reaches outside the process through, apart from
/// the file system.
struct CommandLineTool: Sendable {
    /// The CLI executable, which the helpers are located from. Without one, the invoked
    /// program name is used.
    var executableURL: URL? = Bundle.main.executableURL
    var processRunner: any CommandRunning = ProcessRunner()
    var console: Console = .standard
    /// Supplies the wizard's answers. Without one, the wizard reads standard input.
    var readLine: PrivateHeaderKitInputReader? = nil
    var clearScreen: @Sendable () -> Void = clearInteractiveScreen
    /// Where the wizard writes when it started without `--out`.
    var defaultOutputBaseDirectory: @Sendable () -> String = defaultInteractiveOutputBaseDirectory

    /// Returns the exit status of the process.
    func run(_ arguments: [String]) async -> Int32 {
        let command: ParsedCommand
        do {
            command = try ParsedCommand(arguments: arguments)
        } catch let error as PrivateHeaderKitCLIError {
            console.error("error: \(error.description)")
            return 1
        } catch {
            let message = PrivateHeaderKitArguments.fullMessage(for: error)
            let exitCode = PrivateHeaderKitArguments.exitCode(for: error).rawValue
            let logger = exitCode == 0 ? console.output : console.error
            for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
                logger(String(line))
            }
            return exitCode
        }

        let executableURL = executableURL
            ?? URL(fileURLWithPath: arguments.first ?? "privateheaderkit", isDirectory: false)
        let standardInput: PrivateHeaderKitInputSession?
        if case .interactiveGenerate = command, readLine == nil {
            standardInput = PrivateHeaderKitInputSession()
        } else {
            standardInput = nil
        }
        let finishInput: PrivateHeaderKitInputFinalizer = {
            try await standardInput?.finish()
        }

        let exitCode: Int32
        do {
            switch command {
            case .decompile(let options):
                exitCode = try await DecompileCommand(
                    options: options,
                    processRunner: processRunner,
                    console: console
                ).run()
            case .search(let options):
                exitCode = try SearchCommand(options: options, console: console).run()
            case .interactiveGenerate(let outputBaseDirectory):
                let defaultOutputBaseDirectory = defaultOutputBaseDirectory
                exitCode = try await GenerationWizard(
                    outputBaseDirectory: { outputBaseDirectory ?? defaultOutputBaseDirectory() },
                    executableURL: executableURL,
                    processRunner: processRunner,
                    console: console,
                    readLine: readLine ?? { try await standardInput?.readLine() },
                    finishInput: finishInput,
                    clearScreen: clearScreen
                ).run()
            case .generateSSH(let options):
                exitCode = try await SSHGenerateCommand(
                    options: options,
                    executableURL: executableURL,
                    processRunner: processRunner,
                    console: console
                ).run()
            case .generate(let options):
                exitCode = try await GenerateCommand(
                    options: options,
                    executableURL: executableURL,
                    processRunner: processRunner,
                    console: console
                ).run()
            }
        } catch is CancellationError {
            exitCode = 130
        } catch {
            console.error("error: \(error)")
            exitCode = 2
        }
        do {
            try await finishInput()
        } catch {
            console.error("error: unable to restore interactive input: \(error)")
            return exitCode == 0 ? 1 : exitCode
        }
        return exitCode
    }
}
