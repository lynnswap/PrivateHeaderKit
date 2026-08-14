import Foundation
import Testing
import os

#if os(macOS)
import ArgumentParser
import UnixSignals

@testable import PrivateHeaderKitInstall
@testable import PrivateHeaderKitInstallCLI

@Suite
struct PrivateHeaderKitInstallCLIParsingTests {
    @Test func publicHelpIsGeneratedAndPrivateReleaseFlagsStayHidden() {
        let help = PrivateHeaderKitInstallCommand.helpMessage(columns: 100)

        #expect(help.contains("--prefix"))
        #expect(help.contains("--bindir"))
        #expect(help.contains("--configuration"))
        #expect(help.contains("--dry-run"))
        #expect(help.contains("swift build -c release --product privateheaderkit-install"))
        #expect(help.contains(".build/release/privateheaderkit-install"))
        #expect(help.contains("swift run -c release privateheaderkit-install"))
        #expect(!help.contains("--release-dir"))
        #expect(!help.contains("--expected-version"))
        #expect(!help.contains("--create-release-manifest"))
        #expect(!help.contains("--artifact-dir"))
    }

    @Test func currentReleaseScriptsArgvRemainParseable() throws {
        let release = try parseInstallCommand([
            "--release-dir", "/tmp/privateheaderkit-release",
            "--expected-version", "v1.2.3",
            "--expected-commit", String(repeating: "a", count: 40),
            "--prefix", "/tmp/prefix",
        ])
        guard
            case .install(let releaseOptions) = try release.resolvedCommand(
                environment: [:]
            )
        else {
            Issue.record("expected release installation command")
            return
        }
        #expect(releaseOptions.releaseDirectory == "/tmp/privateheaderkit-release")
        #expect(releaseOptions.expectedReleaseVersion == "v1.2.3")
        #expect(releaseOptions.prefix == "/tmp/prefix")

        let manifest = try parseInstallCommand([
            "--create-release-manifest",
            "--artifact-dir", "/tmp/artifacts",
            "--version", "v1.2.3",
            "--commit", String(repeating: "b", count: 40),
            "--output", "/tmp/artifacts/release.json",
        ])
        guard
            case .createReleaseManifest(let manifestOptions) = try manifest.resolvedCommand(
                environment: [:]
            )
        else {
            Issue.record("expected release manifest command")
            return
        }
        #expect(manifestOptions.artifactDirectory == "/tmp/artifacts")
        #expect(manifestOptions.version == "v1.2.3")
        #expect(manifestOptions.output == "/tmp/artifacts/release.json")
    }

    @Test func commandLinePrefixOrBindirOwnsPrecedenceOverTheEnvironment() throws {
        let prefixCommand = try parseInstallCommand([
            "--prefix", "/cli/prefix",
            "--configuration", "debug",
            "--dry-run",
        ])
        guard
            case .install(let prefixOptions) = try prefixCommand.resolvedCommand(
                environment: [
                    "PREFIX": "/env/prefix",
                    "BINDIR": "/env/bin",
                ]
            )
        else {
            Issue.record("expected install command")
            return
        }
        #expect(prefixOptions.prefix == "/cli/prefix")
        #expect(prefixOptions.bindir == nil)
        #expect(prefixOptions.buildConfiguration == .debug)
        #expect(prefixOptions.dryRun)

        let bindirCommand = try parseInstallCommand([
            "--bindir", "/cli/bin",
        ])
        guard
            case .install(let bindirOptions) = try bindirCommand.resolvedCommand(
                environment: [
                    "PREFIX": "/env/prefix",
                    "BINDIR": "/env/bin",
                ]
            )
        else {
            Issue.record("expected install command")
            return
        }
        #expect(bindirOptions.prefix == nil)
        #expect(bindirOptions.bindir == "/cli/bin")
    }

    @Test func environmentPrecedenceAndWhitespaceFollowOneDeterministicRule() throws {
        let command = try parseInstallCommand([])

        do {
            _ = try command.resolvedCommand(
                environment: [
                    "PREFIX": "/env/prefix",
                    "BINDIR": "/env/bin",
                ]
            )
            Issue.record("expected conflicting environment values to fail")
        } catch is InstallError {
            // Expected.
        }

        guard
            case .install(let prefixOnly) = try command.resolvedCommand(
                environment: ["PREFIX": "/env/prefix"]
            )
        else {
            Issue.record("expected install command")
            return
        }
        #expect(prefixOnly.prefix == "/env/prefix")
        #expect(prefixOnly.bindir == nil)

        guard
            case .install(let whitespaceIsUnset) = try command.resolvedCommand(
                environment: [
                    "PREFIX": "  \t ",
                    "BINDIR": "/env/bin",
                ]
            )
        else {
            Issue.record("expected install command")
            return
        }
        #expect(whitespaceIsUnset.prefix == nil)
        #expect(whitespaceIsUnset.bindir == "/env/bin")

        guard case .install(let defaults) = try command.resolvedCommand(environment: [:]) else {
            Issue.record("expected install command")
            return
        }
        let defaultLayout = try resolveInstallLayout(
            prefix: defaults.prefix,
            bindir: defaults.bindir
        )
        #expect(defaultLayout.prefix.path.hasSuffix("/.local"))
    }

    @Test func prefixConflictsAndWhitespaceFailIndependentOfArgumentOrder() throws {
        for arguments in [
            ["--prefix", "/prefix", "--bindir", "/bin"],
            ["--bindir", "/bin", "--prefix", "/prefix"],
            ["--prefix", "   "],
            ["--bindir", "\t"],
        ] {
            do {
                let command = try parseInstallCommand(arguments)
                _ = try command.resolvedCommand(environment: [:])
                Issue.record("expected invalid prefix arguments to fail: \(arguments)")
            } catch {
                // Expected.
            }
        }
    }

    @Test func manifestAndInstallModesCannotBeMixed() {
        expectInstallParseFailure([
            "--create-release-manifest",
            "--artifact-dir", "/tmp/artifacts",
            "--version", "v1.0.0",
            "--commit", String(repeating: "c", count: 40),
            "--output", "/tmp/release.json",
            "--prefix", "/tmp/prefix",
        ])
        expectInstallParseFailure([
            "--artifact-dir", "/tmp/artifacts",
        ])
        expectInstallParseFailure([
            "--release-dir", "/tmp/release",
            "--expected-version", "v1.0.0",
            "--expected-commit", String(repeating: "d", count: 40),
            "--configuration", "release",
        ])
    }
}

#if os(macOS)

@Suite
struct PrivateHeaderKitInstallSignalTests {
    @Test func signalExitWaitsForOperationCleanup() async throws {
        try await assertSignalWaitsForCleanup(signal: .sigint, status: 130)
        try await assertSignalWaitsForCleanup(signal: .sigterm, status: 143)
    }

    @Test func noSignalCancellationMapsToSilent130() async {
        let (signals, _) = AsyncStream<UnixSignal>.makeStream()

        do {
            try await runInstallerRoot(
                signals: signals,
                operation: { throw CancellationError() },
                errorLogger: { _ in }
            )
            Issue.record("expected cancellation exit")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 130)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func bufferedSignalWinsTheTerminalRace() async {
        let (signals, continuation) = AsyncStream<UnixSignal>.makeStream()
        continuation.yield(.sigint)

        do {
            try await runInstallerRoot(
                signals: signals,
                operation: {},
                errorLogger: { _ in }
            )
            Issue.record("expected signal exit")
        } catch let exitCode as ExitCode {
            #expect(exitCode.rawValue == 130)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private func assertSignalWaitsForCleanup(
    signal: UnixSignal,
    status: Int32
) async throws {
    let operationStarted = OneShotLatch()
    let cancellationObserved = OneShotLatch()
    let releaseCleanup = OneShotLatch()
    let cleanupFinished = OneShotLatch()
    let log = ThreadSafeLog()
    let (signals, continuation) = AsyncStream<UnixSignal>.makeStream()

    let operation = Task {
        try await runInstallerRoot(
            signals: signals,
            operation: {
                operationStarted.open()
                await withTaskCancellationHandler {
                    await releaseCleanup.wait()
                } onCancel: {
                    cancellationObserved.open()
                }
                cleanupFinished.open()
                if signal == .sigterm {
                    throw SignalCleanupFailure.injected
                }
                throw CancellationError()
            },
            errorLogger: { message in
                log.append(message)
            }
        )
    }

    await operationStarted.wait()
    continuation.yield(signal)
    await cancellationObserved.wait()
    #expect(!cleanupFinished.isOpen)
    releaseCleanup.open()

    do {
        try await operation.value
        Issue.record("expected signal exit")
    } catch let exitCode as ExitCode {
        #expect(exitCode.rawValue == status)
    }
    #expect(cleanupFinished.isOpen)
    if signal == .sigterm {
        #expect(log.messages.count == 1)
        #expect(log.messages[0].contains("SIGTERM"))
    } else {
        #expect(log.messages.isEmpty)
    }
}

private enum SignalCleanupFailure: Error {
    case injected
}

#endif

private enum InstallCLIParseTestError: Error {
    case wrongRootCommand
}

private func parseInstallCommand(
    _ arguments: [String]
) throws -> PrivateHeaderKitInstallCommand {
    guard
        let command = try PrivateHeaderKitInstallCommand.parseAsRoot(arguments)
            as? PrivateHeaderKitInstallCommand
    else {
        throw InstallCLIParseTestError.wrongRootCommand
    }
    return command
}

private func expectInstallParseFailure(_ arguments: [String]) {
    do {
        _ = try parseInstallCommand(arguments)
        Issue.record("expected parsing to fail: \(arguments)")
    } catch {
        // Expected.
    }
}

private final class OneShotLatch: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            guard !state.isOpen else { return [] }
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class ThreadSafeLog: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())

    var messages: [String] {
        storage.withLock { $0 }
    }

    func append(_ message: String) {
        storage.withLock { $0.append(message) }
    }
}

#endif
