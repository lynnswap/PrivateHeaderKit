import ArgumentParser
import Foundation
import PrivateHeaderKitInstall

#if os(macOS)
import UnixSignals
#endif

enum InstallerBuildConfiguration: String, ExpressibleByArgument, Sendable {
    case debug
    case release

    var domainValue: BuildConfiguration {
        switch self {
        case .debug: .debug
        case .release: .release
        }
    }
}

@main
struct PrivateHeaderKitInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "privateheaderkit-install",
        abstract: "Build and install PrivateHeaderKit from a source checkout.",
        discussion: """
            Build the installer, then run it from the checkout:
              swift build -c release --product privateheaderkit-install
              .build/release/privateheaderkit-install

            Or build and run it in one command:
              swift run -c release privateheaderkit-install
            """
    )

    @Option(
        name: .customLong("prefix"),
        help:
            "Install under <prefix>/bin and <prefix>/libexec/privateheaderkit (default: ~/.local)."
    )
    var prefix: String?

    @Option(
        name: .customLong("bindir"),
        help: "Install the stable command symlink here; the prefix is its parent directory."
    )
    var bindir: String?

    @Option(
        name: .customLong("configuration"),
        help: "Build source artifacts with debug or release configuration (default: release)."
    )
    var buildConfiguration: InstallerBuildConfiguration?

    @Flag(help: "Print the version-cohort layout without building or changing files.")
    var dryRun = false

    @Option(name: .customLong("release-dir"), help: .private)
    var releaseDirectory: String?

    @Option(name: .customLong("expected-version"), help: .private)
    var expectedReleaseVersion: String?

    @Option(name: .customLong("expected-commit"), help: .private)
    var expectedReleaseCommit: String?

    @Flag(name: .customLong("create-release-manifest"), help: .private)
    var createReleaseManifest = false

    @Option(name: .customLong("artifact-dir"), help: .private)
    var artifactDirectory: String?

    @Option(name: .customLong("version"), help: .private)
    var manifestVersion: String?

    @Option(name: .customLong("commit"), help: .private)
    var manifestCommit: String?

    @Option(name: .customLong("output"), help: .private)
    var manifestOutput: String?

    mutating func validate() throws {
        if createReleaseManifest {
            guard prefix == nil,
                bindir == nil,
                buildConfiguration == nil,
                !dryRun,
                releaseDirectory == nil,
                expectedReleaseVersion == nil,
                expectedReleaseCommit == nil
            else {
                throw ValidationError(
                    "release-manifest creation options cannot be mixed with installation options"
                )
            }
            guard artifactDirectory != nil,
                manifestVersion != nil,
                manifestCommit != nil,
                manifestOutput != nil
            else {
                throw ValidationError(
                    "--create-release-manifest requires --artifact-dir, --version, --commit, and --output"
                )
            }
        } else if artifactDirectory != nil
            || manifestVersion != nil
            || manifestCommit != nil
            || manifestOutput != nil
        {
            throw ValidationError(
                "--artifact-dir, --version, --commit, and --output require --create-release-manifest"
            )
        }

        if releaseDirectory != nil, buildConfiguration != nil {
            throw ValidationError(
                "--configuration is only valid for source installation and cannot be mixed with --release-dir"
            )
        }
    }

    func resolvedCommand(
        environment: [String: String]
    ) throws -> InstallerCommand {
        if createReleaseManifest {
            return .createReleaseManifest(
                CreateReleaseManifestOptions(
                    artifactDirectory: try requiredPrivateValue(
                        artifactDirectory,
                        option: "--artifact-dir"
                    ),
                    version: try requiredPrivateValue(
                        manifestVersion,
                        option: "--version"
                    ),
                    commit: try requiredPrivateValue(
                        manifestCommit,
                        option: "--commit"
                    ),
                    output: try requiredPrivateValue(
                        manifestOutput,
                        option: "--output"
                    )
                )
            )
        }

        return .install(
            try resolveInstallOptions(
                cliPrefix: prefix,
                cliBindir: bindir,
                dryRun: dryRun,
                buildConfiguration: buildConfiguration?.domainValue,
                releaseDirectory: try optionalPrivateValue(
                    releaseDirectory,
                    option: "--release-dir"
                ),
                expectedReleaseVersion: try optionalPrivateValue(
                    expectedReleaseVersion,
                    option: "--expected-version"
                ),
                expectedReleaseCommit: try optionalPrivateValue(
                    expectedReleaseCommit,
                    option: "--expected-commit"
                ),
                environment: environment
            )
        )
    }

    mutating func run() async throws {
        let command = try resolvedCommand(
            environment: ProcessInfo.processInfo.environment
        )
        #if os(macOS)
        let signals = await UnixSignalsSequence(trapping: .sigint, .sigterm)
        try await runInstallerRoot(
            signals: signals,
            operation: {
                try await executeInstallerCommand(command)
            }
        )
        #else
        try await executeInstallerCommand(command)
        #endif
    }
}

private func requiredPrivateValue(
    _ value: String?,
    option: String
) throws -> String {
    guard let value = try optionalPrivateValue(value, option: option) else {
        throw ValidationError("\(option) is required")
    }
    return value
}

private func optionalPrivateValue(
    _ value: String?,
    option: String
) throws -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ValidationError("\(option) requires a non-empty value")
    }
    return trimmed
}

#if os(macOS)

private enum InstallerCoordinationEvent: Sendable {
    case operationSucceeded
    case operationFailed(any Error)
    case signal(UnixSignal)
    case signalStreamEnded
    case signalStreamFailed(any Error)
}

private enum InstallerCoordinationResult: Sendable {
    case succeeded
    case failed(any Error)
    case signalExit(Int32)
}

func runInstallerRoot<Signals>(
    signals: Signals,
    operation: @escaping @Sendable () async throws -> Void,
    errorLogger: @escaping @Sendable (String) -> Void = logInstallerError
) async throws
where
    Signals: AsyncSequence & Sendable,
    Signals.Element == UnixSignal
{
    do {
        try await coordinateInstallerOperation(
            signals: signals,
            operation: operation,
            errorLogger: errorLogger
        )
    } catch is CancellationError {
        throw ExitCode(130)
    }
}

func coordinateInstallerOperation<Signals>(
    signals: Signals,
    operation: @escaping @Sendable () async throws -> Void,
    errorLogger: @escaping @Sendable (String) -> Void = logInstallerError
) async throws
where
    Signals: AsyncSequence & Sendable,
    Signals.Element == UnixSignal
{
    let result = await withTaskGroup(
        of: InstallerCoordinationEvent.self,
        returning: InstallerCoordinationResult.self
    ) { group in
        group.addTask {
            do {
                try await operation()
                return .operationSucceeded
            } catch {
                return .operationFailed(error)
            }
        }
        group.addTask {
            var iterator = signals.makeAsyncIterator()
            do {
                guard let signal = try await iterator.next() else {
                    return .signalStreamEnded
                }
                return .signal(signal)
            } catch {
                return .signalStreamFailed(error)
            }
        }

        while let event = await group.next() {
            switch event {
            case .operationSucceeded:
                group.cancelAll()
                var bufferedSignal: UnixSignal?
                while let terminal = await group.next() {
                    if case .signal(let signal) = terminal {
                        bufferedSignal = signal
                    }
                }
                if let bufferedSignal {
                    return .signalExit(128 + bufferedSignal.rawValue)
                }
                return .succeeded

            case .operationFailed(let error):
                group.cancelAll()
                var bufferedSignal: UnixSignal?
                while let terminal = await group.next() {
                    if case .signal(let signal) = terminal {
                        bufferedSignal = signal
                    }
                }
                if let bufferedSignal {
                    if !(error is CancellationError) {
                        errorLogger(
                            "error while shutting down after \(bufferedSignal): \(error)"
                        )
                    }
                    return .signalExit(128 + bufferedSignal.rawValue)
                }
                return .failed(error)

            case .signal(let signal):
                group.cancelAll()
                var operationFailure: (any Error)?
                while let terminal = await group.next() {
                    if case .operationFailed(let error) = terminal {
                        operationFailure = error
                    }
                }
                if let operationFailure,
                    !(operationFailure is CancellationError)
                {
                    errorLogger(
                        "error while shutting down after \(signal): \(operationFailure)"
                    )
                }
                return .signalExit(128 + signal.rawValue)

            case .signalStreamEnded:
                continue

            case .signalStreamFailed(let error):
                group.cancelAll()
                while await group.next() != nil {}
                return .failed(error)
            }
        }
        return .failed(CancellationError())
    }

    switch result {
    case .succeeded:
        return
    case .failed(let error):
        throw error
    case .signalExit(let status):
        throw ExitCode(status)
    }
}

private func logInstallerError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

#endif
