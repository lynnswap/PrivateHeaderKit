import Foundation
import PrivateHeaderKitTestSupport
import PrivateHeaderKitTooling
import Testing
@testable import PrivateHeaderKitCLI

struct PrivateHeaderKitDecompilationTests {
    @Test func parsesFileAndSharedCacheSources() throws {
        #expect(try parsePrivateHeaderKitCommand([
            "privateheaderkit", "decompile", "--binary", "/tmp/Foo", "--symbol=_CFunction",
        ]) == .decompile(command()))
        let parsed = try parsePrivateHeaderKitCommand([
            "privateheaderkit", "decompile", "--shared-cache", "/cache", "--image", "/usr/lib/Foo",
            "--symbol=-[Foo method:]", "--ghidra-home", "/ghidra", "--output", "/result.c",
            "--processor", "AARCH64:LE:64:AppleSilicon", "--timeout", "30",
        ])
        guard case .decompile(let value) = parsed else { Issue.record("wrong command"); return }
        #expect(value.source == .sharedCache(path: "/cache", image: "/usr/lib/Foo"))
        #expect(value.symbol == "-[Foo method:]")
        #expect(value.timeout == 30)
        #expect(value.outputPath == "/result.c")
    }

    @Test(arguments: [
        ["--symbol", "name"],
        ["--binary", "/Foo", "--shared-cache", "/cache", "--symbol", "name"],
        ["--shared-cache", "/cache", "--symbol", "name"],
        ["--shared-cache", "/cache", "--image", "Foo", "--symbol", "name"],
        ["--binary", "/Foo", "--symbol", ""],
        ["--binary", "/Foo", "--symbol", "name", "--timeout", "0"],
    ]) func rejectsIncompleteOrConflictingRequests(_ arguments: [String]) {
        #expect(throws: (any Error).self) {
            try parsePrivateHeaderKitCommand(["privateheaderkit", "decompile"] + arguments)
        }
    }

    @Test func runsLocallyWithLiteralSymbolInputAndRemovesWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let runner = RecordingCommandRunner()
        let symbol = "-[Foo method:]; $(no-shell)"
        let progress = DecompilationMessages()
        await runner.setStreamingHandler { invocation, environment, cwd in
            #expect(progress.values == ["Analyzing and decompiling with Ghidra..."])
            let cwd = try #require(cwd)
            #expect(!cwd.path.contains("/alias/"))
            #expect(invocation.first == "/Tools/Ghidra/support/analyzeHeadless")
            #expect(environment?["JAVA_HOME"] == "/Tools/Java")
            #expect(!invocation.contains(symbol))
            #expect(try String(contentsOf: cwd.appendingPathComponent("symbol.txt"), encoding: .utf8) == symbol)
            #expect(invocation.contains("-readOnly"))
            #expect(invocation.contains("-deleteProject"))
            try "int found(void) { return 7; }".write(to: cwd.appendingPathComponent("code.c"), atomically: true, encoding: .utf8)
            return .init(status: 0, wasKilled: false, lastLines: [])
        }
        let code = try await decompilePrivateHeaderKitFunction(
            command(symbol: symbol), processRunner: runner,
            environment: ["GHIDRA_HOME": "/Tools/Ghidra", "JAVA_HOME": "/Tools/Java"], temporaryDirectory: alias,
            progressReporter: progress.record
        )
        #expect(code.contains("return 7"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

    @Test func cacheExtractionKeepsEveryOutputInsideTheWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        let ipsw = URL(fileURLWithPath: "tools/ipsw").standardizedFileURL.path
        let progress = DecompilationMessages()
        await runner.setStreamingHandler { invocation, _, cwd in
            let cwd = try #require(cwd)
            if invocation.first == ipsw {
                #expect(progress.values == ["Extracting shared-cache image with ipsw..."])
                #expect(Array(invocation.prefix(5)) == [ipsw, "dyld", "extract", "/cache", "/usr/lib/Foo"])
                for flag in ["--output", "--cache"] {
                    let index = try #require(invocation.firstIndex(of: flag))
                    #expect(invocation[index + 1].hasPrefix(cwd.path + "/"))
                }
            } else {
                #expect(progress.values == [
                    "Extracting shared-cache image with ipsw...",
                    "Analyzing and decompiling with Ghidra...",
                ])
                let index = try #require(invocation.firstIndex(of: "-import"))
                #expect(invocation[index + 1] == cwd.appendingPathComponent("images/Foo").path)
                try "code".write(to: cwd.appendingPathComponent("code.c"), atomically: true, encoding: .utf8)
            }
            return .init(status: 0, wasKilled: false, lastLines: [])
        }
        _ = try await decompilePrivateHeaderKitFunction(
            command(source: .sharedCache(path: "/cache", image: "/usr/lib/Foo"), ipsw: "tools/ipsw"),
            processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root,
            progressReporter: progress.record
        )
        #expect(await runner.streamingCommandSnapshot().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["tool", "script", "missing", "cancel"], [false, true])
    func failuresAndCancellationArePropagatedAfterCleanup(_ failure: String, _ usesCache: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        let progress = DecompilationMessages()
        await runner.setStreamingHandler { invocation, _, cwd in
            if invocation.first == "ipsw" { return .init(status: 0, wasKilled: false, lastLines: []) }
            if failure == "cancel" { throw CancellationError() }
            if failure == "script" {
                try "Symbol not found: _CFunction".write(to: cwd!.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            }
            return .init(status: failure == "tool" ? 42 : 0, wasKilled: false, lastLines: ["test diagnostic"])
        }
        do {
            _ = try await decompilePrivateHeaderKitFunction(
                command(source: usesCache ? .sharedCache(path: "/cache", image: "/usr/lib/Foo") : .binary("/tmp/Foo")),
                processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root,
                progressReporter: progress.record
            )
            Issue.record("failure unexpectedly succeeded")
        } catch {
            if failure == "cancel" {
                #expect(error is CancellationError)
            } else {
                #expect(error is PrivateHeaderKitDecompilationError)
                #expect(String(describing: error).contains(failure == "script" ? "Symbol not found" : "test diagnostic"))
            }
        }
        #expect(progress.values == (usesCache ? ["Extracting shared-cache image with ipsw..."] : [])
            + ["Analyzing and decompiling with Ghidra..."])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func extractionFailureOrCancellationStopsBeforeGhidra(_ cancels: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        let progress = DecompilationMessages()
        await runner.setStreamingHandler { invocation, _, _ in
            #expect(invocation.first == "ipsw")
            if cancels { throw CancellationError() }
            return .init(status: 42, wasKilled: false, lastLines: ["extraction diagnostic"])
        }
        do {
            _ = try await decompilePrivateHeaderKitFunction(
                command(source: .sharedCache(path: "/cache", image: "/usr/lib/Foo")),
                processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root,
                progressReporter: progress.record
            )
            Issue.record("failed extraction unexpectedly succeeded")
        } catch {
            if cancels {
                #expect(error is CancellationError)
            } else {
                #expect(String(describing: error).contains("shared-cache extraction failed: extraction diagnostic"))
            }
        }
        #expect(progress.values == ["Extracting shared-cache image with ipsw..."])
        #expect(await runner.streamingCommandSnapshot().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func precancelledDecompilationDoesNotReportProgressOrCreateWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        let progress = DecompilationMessages()
        let request = command(ghidraHome: "/ghidra")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decompilePrivateHeaderKitFunction(
                request, processRunner: runner, temporaryDirectory: root, progressReporter: progress.record
            )
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(progress.values.isEmpty)
        #expect(await runner.streamingCommandSnapshot().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func progressDoesNotEnterPseudocodeOrOutputFileResults(_ usesCache: Bool, _ writesFile: Bool) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("code.c")
        let code = "int selected(void) { return 7; }\n"
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { invocation, _, cwd in
            if invocation.first != "ipsw" {
                try code.write(to: cwd!.appendingPathComponent("code.c"), atomically: true, encoding: .utf8)
            }
            return .init(status: 0, wasKilled: false, lastLines: ["subprocess log stays buffered"])
        }
        let output = DecompilationMessages()
        let progress = DecompilationMessages()
        let status = try await runPrivateHeaderKitDecompileCommand(
            command(
                source: usesCache ? .sharedCache(path: "/cache", image: "/usr/lib/Foo") : .binary("/tmp/Foo"),
                ghidraHome: "/ghidra", outputPath: writesFile ? file.path : nil
            ),
            processRunner: runner, outputLogger: output.record, progressReporter: progress.record
        )
        #expect(status == 0)
        #expect(output.values == [writesFile ? "Pseudocode: \(file.path)" : code])
        #expect(progress.values == (usesCache ? ["Extracting shared-cache image with ipsw..."] : [])
            + ["Analyzing and decompiling with Ghidra..."])
        if writesFile { #expect(try String(contentsOf: file, encoding: .utf8) == code) }
        for invocation in await runner.streamingCommandSnapshot() {
            #expect(!FileManager.default.fileExists(atPath: try #require(invocation.cwd).path))
        }
    }

    @Test func cleanupFailureRetainsTheOriginalDiagnosticAndWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { _, _, _ in
            .init(status: 1, wasKilled: false, lastLines: ["original failure"])
        }
        do {
            _ = try await decompilePrivateHeaderKitFunction(
                command(), processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root,
                removeDirectory: { _ in throw CocoaError(.fileWriteNoPermission) }
            )
            Issue.record("cleanup failure unexpectedly succeeded")
        } catch {
            #expect(String(describing: error).contains("original failure"))
            #expect(String(describing: error).contains("could not remove decompilation workspace"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
    }

    @Test func existingOutputIsNeverOverwritten() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("existing.c")
        try "keep".write(to: output, atomically: true, encoding: .utf8)
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { _, _, cwd in
            try "new".write(to: cwd!.appendingPathComponent("code.c"), atomically: true, encoding: .utf8)
            return .init(status: 0, wasKilled: false, lastLines: [])
        }
        await #expect(throws: (any Error).self) {
            try await runPrivateHeaderKitDecompileCommand(
                command(ghidraHome: "/ghidra", outputPath: output.path), processRunner: runner, outputLogger: { _ in }
            )
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "keep")
    }

    private func command(
        source: PrivateHeaderKitDecompileCommand.Source = .binary("/tmp/Foo"),
        symbol: String = "_CFunction", ghidraHome: String? = nil,
        ipsw: String = "ipsw", outputPath: String? = nil
    ) -> PrivateHeaderKitDecompileCommand {
        .init(source: source, symbol: symbol, ghidraHome: ghidraHome, ipsw: ipsw,
              processor: nil, timeout: 120, outputPath: outputPath)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class DecompilationMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    var values: [String] {
        lock.withLock { storage }
    }
}
