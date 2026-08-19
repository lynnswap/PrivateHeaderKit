import Foundation
import Testing

@testable import PrivateHeaderKitTooling

@Suite
struct RuntimeReleaseMetadataTests {
    @Test func simulatorSeedMetadataIsReadFromRuntimeRoot() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeRestoreVersion(
            ["IsSeed": true],
            to: root.appendingPathComponent("RestoreVersion.plist")
        )

        #expect(try RuntimeReleaseMetadata.isSeed(in: root, layout: .simulator))
    }

    @Test func absentSeedKeyRepresentsARelease() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent(
            "System/Library/CoreServices/RestoreVersion.plist"
        )
        try writeRestoreVersion(["RestoreVersion": "25.7.83.0.0"], to: metadataURL)

        #expect(try !RuntimeReleaseMetadata.isSeed(in: root, layout: .macOS))
    }

    @Test func missingSimulatorMetadataRepresentsARelease() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try !RuntimeReleaseMetadata.isSeed(in: root, layout: .simulator))
    }

    @Test func missingMacOSMetadataFails() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ToolingError.self) {
            _ = try RuntimeReleaseMetadata.isSeed(in: root, layout: .macOS)
        }
    }

    @Test func unreadableSimulatorMetadataFails() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("RestoreVersion.plist"),
            withIntermediateDirectories: false
        )

        #expect(throws: ToolingError.self) {
            _ = try RuntimeReleaseMetadata.isSeed(in: root, layout: .simulator)
        }
    }

    @Test func malformedMetadataFails() throws {
        let root = try temporaryRuntimeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent("RestoreVersion.plist")
        try writeRestoreVersion(["IsSeed": "true"], to: metadataURL)

        #expect(throws: ToolingError.self) {
            _ = try RuntimeReleaseMetadata.isSeed(in: root, layout: .simulator)
        }
    }
}

private func temporaryRuntimeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RuntimeReleaseMetadataTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeRestoreVersion(_ values: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try PropertyListSerialization.data(
        fromPropertyList: values,
        format: .binary,
        options: 0
    )
    try data.write(to: url)
}
