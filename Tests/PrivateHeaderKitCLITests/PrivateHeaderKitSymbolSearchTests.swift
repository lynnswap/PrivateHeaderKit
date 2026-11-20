import Foundation
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitCLI

struct PrivateHeaderKitSymbolSearchTests {
    @Test func parsesSearchWithoutGenerationInputs() throws {
        #expect(try ParsedCommand(arguments: [
            "privateheaderkit", "search", "Foo::bar(int)", "--in", "/generated", "--exact",
        ]) == .search(.init(query: "Foo::bar(int)", directory: "/generated", exact: true)))
        #expect(throws: (any Error).self) {
            try ParsedCommand(arguments: ["privateheaderkit", "search", "", "--in", "/generated"])
        }
    }

    @Test func searchesOriginalAndDemangledNamesAcrossImages() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("PrivateFrameworks/Foo/Headers")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let list = PrivateHeaderKitSymbolList(imagePath: "/System/Library/PrivateFrameworks/Foo.framework/Foo", symbols: [
            .init(name: "__ZN3Foo3barEi", demangledName: "Foo::bar(int)", visibility: .local),
            .init(name: "_FooCreate", demangledName: "_FooCreate", visibility: .export),
        ])
        try list.tsv.write(to: library.appendingPathComponent("Foo.symbols.tsv"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("user.tsv"), atomically: true, encoding: .utf8)
        let lines = SearchMessages()
        #expect(try search(.init(query: "foo", directory: root.path, exact: false), output: lines) == 0)
        #expect(lines.values.count == 3)
        #expect(lines.values[1].contains("\tlocal\t__ZN3Foo3barEi\tFoo::bar(int)"))
        #expect(lines.values[1].contains(list.imagePath))
        let exactLines = SearchMessages()
        #expect(
            try search(.init(query: "__ZN3Foo3barEi", directory: root.path, exact: true), output: exactLines)
                == 0
        )
        #expect(exactLines.values.count == 2)
        #expect(try search(.init(query: "foo::bar(int)", directory: root.path, exact: true)) == 1)
    }

    @Test func reportsMissingListsWithoutPretendingTheQueryHasNoMatches() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = SearchMessages()
        let errors = SearchMessages()
        let status = try search(
            .init(query: "anything", directory: root.path, exact: false),
            output: output, errors: errors
        )
        #expect(status == 2)
        #expect(output.values.isEmpty)
        #expect(errors.values.count == 1)
        #expect(errors.values.first?.contains("no .symbols.tsv files found") == true)
    }

    @Test(arguments: ["malformed", "encoding"], ["Foo", "Absent"])
    func incompleteSearchKeepsLaterResultsAndReportsEveryBadList(_ failure: String, _ query: String) throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appendingPathComponent("A.symbols.tsv")
        let anotherBad = root.appendingPathComponent("B.symbols.tsv")
        try (failure == "malformed" ? Data("broken".utf8) : Data([0xff, 0xfe, 0xff]))
            .write(to: bad)
        try Data("also broken".utf8).write(to: anotherBad)
        try writeList(to: root.appendingPathComponent("Z.symbols.tsv"))
        let output = SearchMessages()
        let errors = SearchMessages()
        let status = try search(
            .init(query: query, directory: root.path, exact: false),
            output: output, errors: errors
        )
        #expect(status == 2)
        #expect(errors.values.count == 2)
        #expect(errors.values[0].contains(bad.path))
        #expect(errors.values[1].contains(anotherBad.path))
        #expect(output.values.count == (query == "Foo" ? 2 : 1))
        #expect(output.values.allSatisfy { !$0.hasPrefix("error:") })
        if query == "Foo" { #expect(output.values[1].contains("\t_Foo\tFoo")) }
    }

    @Test func traversalFailureDoesNotHideReadableSiblingResults() throws {
        let root = try makeDirectory()
        let unreadable = root.appendingPathComponent("A-unreadable")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try writeList(to: root.appendingPathComponent("Z.symbols.tsv"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        // Elevated processes can bypass mode bits and cannot exercise this failure.
        guard !FileManager.default.isReadableFile(atPath: unreadable.path) else { return }
        let output = SearchMessages()
        let errors = SearchMessages()
        let status = try search(
            .init(query: "Foo", directory: root.path, exact: false),
            output: output, errors: errors
        )
        #expect(status == 2)
        #expect(output.values.count == 2)
        #expect(errors.values.contains { $0.contains(unreadable.path) })
        #expect(!errors.values.contains { $0.contains("no .symbols.tsv files found") })
    }

    @Test func missingRootReportsTraversalFailureInsteadOfMissingLists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing")
        let output = SearchMessages()
        let errors = SearchMessages()
        let status = try search(
            .init(query: "Foo", directory: missing.path, exact: false),
            output: output, errors: errors
        )
        #expect(status == 2)
        #expect(output.values.isEmpty)
        #expect(errors.values.contains { $0.contains(missing.path) })
        #expect(!errors.values.contains { $0.contains("no .symbols.tsv files found") })
    }

    @Test func cancellationAfterTheFinalResultIsNotReportedAsSearchSuccess() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeList(to: root.appendingPathComponent("Foo.symbols.tsv"))
        let task = Task {
            try SearchCommand(
                options: .init(query: "Foo", directory: root.path, exact: false),
                console: Console(
                    output: { line in
                        if line.contains("\t_Foo\tFoo") { withUnsafeCurrentTask { $0?.cancel() } }
                    },
                    error: { _ in Issue.record("cancellation was reported as a file error") }
                )
            ).run()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    private func search(
        _ options: SearchCommand.Options,
        output: SearchMessages = SearchMessages(),
        errors: SearchMessages = SearchMessages()
    ) throws -> Int32 {
        try SearchCommand(
            options: options,
            console: Console(output: output.record, error: errors.record)
        ).run()
    }

    private func writeList(to url: URL) throws {
        let list = PrivateHeaderKitSymbolList(imagePath: "/System/Library/Foo", symbols: [
            .init(name: "_Foo", demangledName: "Foo", visibility: .export)
        ])
        try list.tsv.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

private final class SearchMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ message: String) {
        lock.withLock { storage.append(message) }
    }

    var values: [String] {
        lock.withLock { storage }
    }
}
