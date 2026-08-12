import Foundation
import PrivateHeaderKitCore
import Testing

@testable import PrivateHeaderKitCLI

@Suite
struct PrivateHeaderKitProgressRenderingTests {
    @Test func nonTerminalOutputOmitsSuccessfulTargetsAndReportsOnlyFailures() {
        let output = ProgressTextRecorder()
        let failures = ProgressTextRecorder()
        let renderer = PrivateHeaderKitProgressOutputLogger(
            outputLogger: { output.append($0) },
            failureLogger: { failures.append($0) },
            artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
            inlineProgressEnabled: false,
            startsTimer: false
        )

        renderer.report(.runStarted(runID: .init(rawValue: "run-001"), totalTargetCount: 2))
        renderer.report(.targetStarted(index: 1, total: 2, displayName: "Foo"))
        renderer.report(
            .targetFinished(
                index: 1,
                total: 2,
                displayName: "Foo",
                status: .completed,
                failureSummary: nil
            )
        )
        renderer.report(.targetStarted(index: 2, total: 2, displayName: "Bar"))
        renderer.report(
            .targetFinished(
                index: 2,
                total: 2,
                displayName: "Bar",
                status: .failed,
                failureSummary: "objc noise\nprivateheaderkit: error: missing image"
            )
        )

        #expect(
            output.values == [
                "Generation run-001: 2 targets → /tmp/generated-headers/source"
            ])
        #expect(
            failures.values == [
                "[2/2] Bar failed",
                "  privateheaderkit: error: missing image",
            ])
    }

    @Test func terminalOutputCyclesDotsAndReusesTheSuccessfulTargetLine() {
        let output = ProgressTextRecorder()
        let failures = ProgressTextRecorder()
        let inline = ProgressTextRecorder()
        let renderer = PrivateHeaderKitProgressOutputLogger(
            outputLogger: { output.append($0) },
            failureLogger: { failures.append($0) },
            artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
            inlineProgressEnabled: true,
            inlineWriter: { inline.append($0) },
            startsTimer: false
        )

        renderer.report(.targetStarted(index: 1, total: 2, displayName: "Foo"))
        renderer.advanceIndicatorForTesting()
        renderer.advanceIndicatorForTesting()
        renderer.advanceIndicatorForTesting()
        renderer.report(
            .targetFinished(
                index: 1,
                total: 2,
                displayName: "Foo",
                status: .completed,
                failureSummary: nil
            )
        )
        renderer.report(.targetStarted(index: 2, total: 2, displayName: "Bar"))
        renderer.report(
            .targetFinished(
                index: 2,
                total: 2,
                displayName: "Bar",
                status: .failed,
                failureSummary: "failed to dump"
            )
        )
        renderer.report(
            .runFinished(
                .init(
                    runID: .init(rawValue: "run-001"),
                    status: .failed,
                    targetCounts: .init(total: 2, completed: 1, failed: 1),
                    artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
                    stateDatabaseURL: URL(fileURLWithPath: "/tmp/generation.sqlite")
                )
            )
        )

        let rendered = inline.values.joined()
        #expect(rendered.contains("\r[1/2] Foo ."))
        #expect(rendered.contains("\r[1/2] Foo .."))
        #expect(rendered.contains("\r[1/2] Foo ..."))
        #expect(rendered.contains("\r[1/2] Foo completed"))
        #expect(rendered.contains("\r[2/2] Bar ."))
        #expect(rendered.contains("\r[2/2] Bar failed\n"))
        #expect(inline.values.count(where: { $0 == "\u{001B}[?25l" }) == 1)
        #expect(inline.values.count(where: { $0 == "\u{001B}[?25h" }) == 1)
        #expect(output.values.isEmpty)
        #expect(failures.values == ["  failed to dump"])
    }

    @Test func runFinishedClearsTheLastSuccessfulTargetAndIgnoresLateTicks() {
        let inline = ProgressTextRecorder()
        let renderer = PrivateHeaderKitProgressOutputLogger(
            outputLogger: { _ in },
            failureLogger: { _ in },
            artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
            inlineProgressEnabled: true,
            inlineWriter: { inline.append($0) },
            startsTimer: false,
            inlineColumnCount: 80
        )

        renderer.report(.targetStarted(index: 1, total: 1, displayName: "Foo"))
        renderer.report(
            .targetFinished(
                index: 1,
                total: 1,
                displayName: "Foo",
                status: .completed,
                failureSummary: nil
            )
        )
        renderer.report(
            .runFinished(
                .init(
                    runID: .init(rawValue: "run-001"),
                    status: .completed,
                    targetCounts: .init(total: 1, completed: 1),
                    artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
                    stateDatabaseURL: URL(fileURLWithPath: "/tmp/generation.sqlite")
                )
            )
        )
        renderer.advanceIndicatorForTesting()

        #expect(
            inline.values == [
                "\u{001B}[?25l",
                "\r[1/1] Foo .",
                "\r[1/1] Foo completed",
                "\r                   \r",
                "\u{001B}[?25h",
            ])
    }

    @Test func runFinishedWithoutTargetResultStopsAnActiveIndicator() {
        let inline = ProgressTextRecorder()
        let renderer = PrivateHeaderKitProgressOutputLogger(
            outputLogger: { _ in },
            failureLogger: { _ in },
            artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
            inlineProgressEnabled: true,
            inlineWriter: { inline.append($0) },
            startsTimer: false,
            inlineColumnCount: 80
        )

        renderer.report(.targetStarted(index: 1, total: 1, displayName: "Foo"))
        renderer.report(
            .runFinished(
                .init(
                    runID: .init(rawValue: "run-001"),
                    status: .failed,
                    targetCounts: .init(total: 1, failed: 1),
                    artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
                    stateDatabaseURL: URL(fileURLWithPath: "/tmp/generation.sqlite")
                )
            )
        )
        renderer.advanceIndicatorForTesting()

        #expect(
            inline.values == [
                "\u{001B}[?25l",
                "\r[1/1] Foo .",
                "\r           \r",
                "\u{001B}[?25h",
            ])
    }

    @Test func terminalOutputTruncatesLongTargetsToTheTerminalWidth() {
        let inline = ProgressTextRecorder()
        let renderer = PrivateHeaderKitProgressOutputLogger(
            outputLogger: { _ in },
            failureLogger: { _ in },
            artifactDirectory: URL(fileURLWithPath: "/tmp/generated-headers/source"),
            inlineProgressEnabled: true,
            inlineWriter: { inline.append($0) },
            startsTimer: false,
            inlineColumnCount: 32
        )

        renderer.report(
            .targetStarted(
                index: 24,
                total: 6701,
                displayName: "Frameworks/AppKit.framework/XPCServices/DefaultSyncService.xpc"
            )
        )

        let line = inline.values.last.map { String($0.dropFirst()) }
        #expect(line.map(privateHeaderKitTestTerminalWidth) == 32)
        #expect(line?.contains("…") == true)
        #expect(line?.contains("SyncService.xpc") == true)
    }
}

private final class ProgressTextRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private func privateHeaderKitTestTerminalWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(into: 0) { width, scalar in
        width += scalar.isASCII ? 1 : 2
    }
}
