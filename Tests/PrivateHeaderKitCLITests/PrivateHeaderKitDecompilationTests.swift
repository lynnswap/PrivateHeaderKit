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
        await runner.setStreamingHandler { invocation, environment, cwd in
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
            environment: ["GHIDRA_HOME": "/Tools/Ghidra", "JAVA_HOME": "/Tools/Java"], temporaryDirectory: alias
        )
        #expect(code.contains("return 7"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: actual.path).isEmpty)
    }

    @Test func cacheExtractionKeepsEveryOutputInsideTheWorkspace() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        let ipsw = URL(fileURLWithPath: "tools/ipsw").standardizedFileURL.path
        await runner.setStreamingHandler { invocation, _, cwd in
            let cwd = try #require(cwd)
            if invocation.first == ipsw {
                #expect(Array(invocation.prefix(5)) == [ipsw, "dyld", "extract", "/cache", "/usr/lib/Foo"])
                for flag in ["--output", "--cache"] {
                    let index = try #require(invocation.firstIndex(of: flag))
                    #expect(invocation[index + 1].hasPrefix(cwd.path + "/"))
                }
            } else {
                let index = try #require(invocation.firstIndex(of: "-import"))
                #expect(invocation[index + 1] == cwd.appendingPathComponent("images/Foo").path)
                try "code".write(to: cwd.appendingPathComponent("code.c"), atomically: true, encoding: .utf8)
            }
            return .init(status: 0, wasKilled: false, lastLines: [])
        }
        _ = try await decompilePrivateHeaderKitFunction(
            command(source: .sharedCache(path: "/cache", image: "/usr/lib/Foo"), ipsw: "tools/ipsw"),
            processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root
        )
        #expect(await runner.streamingCommandSnapshot().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["tool", "script", "missing", "cancel"])
    func failuresAndCancellationArePropagatedAfterCleanup(_ failure: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingCommandRunner()
        await runner.setStreamingHandler { _, _, cwd in
            if failure == "cancel" { throw CancellationError() }
            if failure == "script" {
                try "Symbol not found: _CFunction".write(to: cwd!.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
            }
            return .init(status: failure == "tool" ? 42 : 0, wasKilled: false, lastLines: ["test diagnostic"])
        }
        do {
            _ = try await decompilePrivateHeaderKitFunction(
                command(), processRunner: runner, environment: ["GHIDRA_HOME": "/ghidra"], temporaryDirectory: root
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
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
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
