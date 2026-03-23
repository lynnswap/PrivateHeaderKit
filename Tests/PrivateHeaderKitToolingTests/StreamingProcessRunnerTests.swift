import Foundation
import Testing
@testable import PrivateHeaderKitTooling

#if canImport(Darwin)
import Darwin
#endif

#if os(macOS)
private final class LockedDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

private func shellCommand(_ script: String) -> [String] {
    ["/bin/zsh", "-lc", script]
}

private func testHelperExecutableURL() throws -> URL {
    let fileManager = FileManager.default
    let helperName = "PrivateHeaderKitToolingTestHelper"
    let configurations = ["debug", "release", "Debug", "Release"]
    let environment = ProcessInfo.processInfo.environment

    func helperURL(in buildDir: URL) -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: buildDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for configuration in configurations {
            let fallback = buildDir
                .appendingPathComponent(configuration, isDirectory: true)
                .appendingPathComponent(helperName, isDirectory: false)
            if fileManager.isExecutableFile(atPath: fallback.path) {
                return fallback
            }
        }

        for entry in entries {
            for configuration in configurations {
                let candidate = entry
                    .appendingPathComponent(configuration, isDirectory: true)
                    .appendingPathComponent(helperName, isDirectory: false)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }

    let configuredBuildPaths = [
        environment["SWIFTPM_BUILD_DIR"],
        environment["SWIFT_BUILD_PATH"],
        environment["BUILD_DIR"],
        environment["SYMROOT"],
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }

    for buildPath in configuredBuildPaths {
        let buildDir = URL(fileURLWithPath: buildPath, isDirectory: true)
        if let helperURL = helperURL(in: buildDir) {
            return helperURL
        }
    }

    var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)

    for _ in 0..<8 {
        let buildDir = current.appendingPathComponent(".build", isDirectory: true)
        if fileManager.fileExists(atPath: buildDir.path) {
            if let helperURL = helperURL(in: buildDir) {
                return helperURL
            }
        }
        current.deleteLastPathComponent()
    }

    throw NSError(domain: "StreamingProcessRunnerTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "helper executable not found"])
}

private func runHelper(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = try testHelperExecutableURL()
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    let group = DispatchGroup()
    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func set(_ data: Data) {
            lock.lock()
            value = data
            lock.unlock()
        }

        func get() -> Data {
            lock.lock()
            let data = value
            lock.unlock()
            return data
        }
    }

    let stdoutBox = DataBox()
    let stderrBox = DataBox()

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        group.leave()
    }

    process.waitUntilExit()
    group.wait()

    let stdout = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrBox.get(), encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

@Suite struct StreamingProcessRunnerTests {
    @Test func helperCapturesStdoutAndStderrAndForwardsPassthrough() throws {
        let passthrough = LockedDataBox()

        let result = try runStreamingSubprocess(
            shellCommand("print -r -- stdout-line; print -u2 -- stderr-line; print -r -- tail-line"),
            streamOutput: true,
            passthrough: { data in
                passthrough.append(data)
            }
        )

        let forwarded = String(data: passthrough.snapshot(), encoding: .utf8) ?? ""
        #expect(result.status == 0)
        #expect(result.wasKilled == false)
        #expect(result.lastLines.contains("stdout-line"))
        #expect(result.lastLines.contains("stderr-line"))
        #expect(result.lastLines.contains("tail-line"))
        #expect(forwarded.contains("stdout-line"))
        #expect(forwarded.contains("stderr-line"))
        #expect(forwarded.contains("tail-line"))
    }

    @Test func helperUsesNullDeviceWhenParentStdinIsClosed() throws {
        let result = try runHelper(["stdin-closed"])

        #expect(result.status == 0)
        #expect(result.stdout.contains("stdin-ok"))
        #expect(result.stderr.isEmpty)
    }

    @Test func helperWrapsLaunchFailureWithCommandAndUnderlyingError() throws {
        let missingCWD = URL(fileURLWithPath: "/tmp/phk-missing-\(UUID().uuidString)", isDirectory: true)

        do {
            _ = try runStreamingSubprocess(
                ["/usr/bin/true"],
                cwd: missingCWD,
                streamOutput: false,
                passthrough: { _ in }
            )
            Issue.record("expected launch failure")
        } catch let error as ToolingError {
            guard case .processLaunchFailed(let command, let underlying) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(command == ["/usr/bin/true"])
            #expect(!underlying.isEmpty)
            #expect(error.description.contains("failed to launch process: /usr/bin/true"))
        }
    }

    @Test func runStreamingHandlesRepeatedShortLivedProcesses() throws {
        for _ in 0..<200 {
            let result = try runStreamingSubprocess(
                ["/usr/bin/true"],
                streamOutput: false,
                passthrough: { _ in }
            )
            #expect(result.status == 0)
            #expect(result.wasKilled == false)
        }
    }
}
#endif
