import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@testable import PrivateHeaderKitCLI

@Suite
struct RawDumpReportIOTests {
    @Test func openedReportKeepsItsInodeWhenPathIsReplaced() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("report.json")
        let replacementURL = root.appendingPathComponent("replacement.json")
        let openedContents = Data("opened-inode".utf8)
        let replacementContents = Data("replacement-inode".utf8)
        try openedContents.write(to: reportURL)

        let openedReport = try RawDumpReportIO.OpenedFile(at: reportURL)
        try replacementContents.write(to: replacementURL)
        let renameResult = replacementURL.path.withCString { replacementPath in
            reportURL.path.withCString { reportPath in
                systemRename(replacementPath, reportPath)
            }
        }
        #expect(renameResult == 0)

        #expect(
            try openedReport.read(maximumByteCount: 1_024) == openedContents
        )
        #expect(
            try RawDumpReportIO.read(at: reportURL, maximumByteCount: 1_024)
                == replacementContents
        )
    }

    @Test func oversizedRegularReportIsRejectedWithItsObservedSize() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let reportURL = root.appendingPathComponent("oversized.json")
        try Data(count: 65).write(to: reportURL)

        #expect(throws: RawDumpReportIO.Failure.tooLarge(actual: 65)) {
            _ = try RawDumpReportIO.read(at: reportURL, maximumByteCount: 64)
        }
    }

    @Test func nonRegularAndSymbolicLinkReportsAreRejected() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let directoryURL = root.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        #expect(throws: RawDumpReportIO.Failure.notRegularFile) {
            _ = try RawDumpReportIO.read(at: directoryURL, maximumByteCount: 64)
        }

        let fifoURL = root.appendingPathComponent("fifo")
        let fifoResult = fifoURL.path.withCString { path in
            systemMakeFIFO(path, mode_t(0o600))
        }
        #expect(fifoResult == 0)
        #expect(throws: RawDumpReportIO.Failure.notRegularFile) {
            _ = try RawDumpReportIO.read(at: fifoURL, maximumByteCount: 64)
        }

        #expect(throws: RawDumpReportIO.Failure.notRegularFile) {
            _ = try RawDumpReportIO.read(
                at: URL(fileURLWithPath: "/dev/null"),
                maximumByteCount: 64
            )
        }

        let targetURL = root.appendingPathComponent("target.json")
        let symbolicLinkURL = root.appendingPathComponent("link.json")
        try Data("target".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: targetURL
        )
        do {
            _ = try RawDumpReportIO.read(at: symbolicLinkURL, maximumByteCount: 64)
            Issue.record("expected symbolic-link report rejection")
        } catch RawDumpReportIO.Failure.openFailed {
            // O_NOFOLLOW rejects the final symbolic-link component before any bytes are read.
        } catch {
            Issue.record("unexpected symbolic-link report error: \(error)")
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawDumpReportIOTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func systemRename(
    _ source: UnsafePointer<CChar>,
    _ destination: UnsafePointer<CChar>
) -> Int32 {
#if canImport(Darwin)
    Darwin.rename(source, destination)
#elseif canImport(Glibc)
    Glibc.rename(source, destination)
#endif
}

private func systemMakeFIFO(
    _ path: UnsafePointer<CChar>,
    _ permissions: mode_t
) -> Int32 {
#if canImport(Darwin)
    Darwin.mkfifo(path, permissions)
#elseif canImport(Glibc)
    Glibc.mkfifo(path, permissions)
#endif
}
