import Foundation
@_spi(Diagnostics) import MachOObjCSection
import Testing
@testable import PrivateHeaderKitRawDumpCore

struct ObjCChainedBindIntegrationTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["PHK_RUN_INTEGRATION_TESTS"] == "1"
            && ProcessInfo.processInfo.environment["PHK_OBJC_BIND_RUNTIME_ROOT"] != nil),
        arguments: [
            ("AdSupport", "ASIdentifierManager"),
            ("BrowserKit", "BEBrowserData"),
            ("SensorKit", "SRSensorReader"),
            ("MetricKit", "MXMetricManager"),
        ]
    )
    func fileBackedDumpResolvesClassBinds(framework: String, expectedClass: String) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["PHK_OBJC_BIND_RUNTIME_ROOT"])
        let binary = URL(fileURLWithPath: root)
            .appendingPathComponent("System/Library/Frameworks/\(framework).framework/\(framework)")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PHK-objc-binds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = try MachOFile(url: binary)
        let roots = file.objc.readRoots()
        #expect(roots.tableDiagnostics.isEmpty)
        for cls in roots.classes64 ?? [] {
            let ro = try #require(cls.classROData(in: file))
            let name = try #require(ro.name(in: file))
            #expect(isSaneObjCTypeName(name))
        }

        // Exercise file parsing without runtime supplementation hiding missing classes.
        let options = DumpOptions(outputDir: directory, useRuntimeFallback: false)
        try await run(parsed: .init(options: options, inputPath: binary.path))
        let header = try String(
            contentsOf: directory.appendingPathComponent("\(expectedClass).h"),
            encoding: .utf8
        )
        #expect(header.contains("@interface \(expectedClass)"))
        if framework == "AdSupport" {
            #expect(header.contains("+ (id)sharedManager;"))
        }
        #expect(options.objcDiagnostics.report.diagnostics.isEmpty)
    }
}
