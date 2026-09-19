import Foundation
import PrivateHeaderKitTooling
import Testing
@testable import PrivateHeaderKitCLI

struct PrivateHeaderKitGhidraIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHK_RUN_INTEGRATION_TESTS"] == "1"))
    func decompilesSelectedNativeFunctionsAndReportsInvalidSelections() async throws {
        let ghidraHome = try #require(ProcessInfo.processInfo.environment["GHIDRA_HOME"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("probe.mm")
        try #"""
        #import <Foundation/Foundation.h>
        extern "C" {
            int PHKGlobal = 0;
            __attribute__((noinline)) void PHKWrite(int value) {
                if (value > 3) PHKGlobal = value; else PHKGlobal = 7;
            }
        }
        namespace PHKProbe { void call(int value) { PHKWrite(value); } }
        @interface PHKObjCProbe : NSObject
        - (void)write:(int)value;
        @end
        @implementation PHKObjCProbe
        - (void)write:(int)value { PHKWrite(value); }
        @end
        """#.write(to: source, atomically: true, encoding: .utf8)
        let first = root.appendingPathComponent("first.mm")
        let second = root.appendingPathComponent("second.mm")
        try "static __attribute__((noinline)) int PHKDuplicate(int v) { return v + 1; } int PHKFirst(int v) { return PHKDuplicate(v); }"
            .write(to: first, atomically: true, encoding: .utf8)
        try "static __attribute__((noinline)) int PHKDuplicate(int v) { return v + 2; } int PHKSecond(int v) { return PHKDuplicate(v); }"
            .write(to: second, atomically: true, encoding: .utf8)
        let binary = root.appendingPathComponent("libPHKProbe.dylib")
        _ = try await ProcessRunner().runCapture([
            "xcrun", "clang++", "-std=c++17", "-O0", "-g0", "-dynamiclib",
            source.path, first.path, second.path, "-framework", "Foundation", "-o", binary.path,
        ])
        func command(_ symbol: String) -> PrivateHeaderKitDecompileCommand {
            .init(source: .binary(binary.path), symbol: symbol, ghidraHome: ghidraHome,
                  ipsw: "ipsw", processor: nil, timeout: 120, outputPath: nil)
        }
        for name in ["_PHKWrite", "__ZN8PHKProbe4callEi", "-[PHKObjCProbe write:]"] {
            let code = try await decompilePrivateHeaderKitFunction(command(name))
            #expect(code.contains("Ghidra pseudocode"))
            #expect(code.contains(name == "_PHKWrite" ? "PHKGlobal" : "PHKWrite"))
        }
        for (name, message) in [
            ("_PHKMissing", "Symbol not found"),
            ("_PHKGlobal", "not a recognized function"),
            ("__ZL12PHKDuplicatei", "Symbol is ambiguous"),
        ] {
            do {
                _ = try await decompilePrivateHeaderKitFunction(command(name))
                Issue.record("invalid selection unexpectedly decompiled: \(name)")
            } catch {
                #expect(String(describing: error).contains(message))
            }
        }
    }
}
