import Foundation
import PrivateHeaderKitHelperProtocol
import Testing
@testable import PrivateHeaderKitCLI

struct PrivateHeaderKitSymbolSearchTests {
    @Test func parsesSearchWithoutGenerationInputs() throws {
        #expect(try parsePrivateHeaderKitCommand([
            "privateheaderkit", "search", "Foo::bar(int)", "--in", "/generated", "--exact",
        ]) == .search(.init(query: "Foo::bar(int)", directory: "/generated", exact: true)))
        #expect(throws: (any Error).self) {
            try parsePrivateHeaderKitCommand(["privateheaderkit", "search", "", "--in", "/generated"])
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
        var lines: [String] = []
        #expect(try runPrivateHeaderKitSearchCommand(
            .init(query: "foo", directory: root.path, exact: false), outputLogger: { lines.append($0) }
        ) == 0)
        #expect(lines.count == 3)
        #expect(lines[1].contains("\tlocal\t__ZN3Foo3barEi\tFoo::bar(int)"))
        #expect(lines[1].contains(list.imagePath))
        lines.removeAll()
        #expect(try runPrivateHeaderKitSearchCommand(
            .init(query: "__ZN3Foo3barEi", directory: root.path, exact: true), outputLogger: { lines.append($0) }
        ) == 0)
        #expect(lines.count == 2)
        #expect(try runPrivateHeaderKitSearchCommand(
            .init(query: "foo::bar(int)", directory: root.path, exact: true), outputLogger: { _ in }
        ) == 1)
    }

    @Test func reportsMissingListsWithoutPretendingTheQueryHasNoMatches() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var output: [String] = []
        var errors: [String] = []
        let status = try runPrivateHeaderKitSearchCommand(
            .init(query: "anything", directory: root.path, exact: false),
            outputLogger: { output.append($0) }, errorLogger: { errors.append($0) }
        )
        #expect(status == 2)
        #expect(output.isEmpty)
        #expect(errors.count == 1)
        #expect(errors.first?.contains("no .symbols.tsv files found") == true)
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
        var output: [String] = []
        var errors: [String] = []
        let status = try runPrivateHeaderKitSearchCommand(
            .init(query: query, directory: root.path, exact: false),
            outputLogger: { output.append($0) }, errorLogger: { errors.append($0) }
        )
        #expect(status == 2)
        #expect(errors.count == 2)
        #expect(errors[0].contains(bad.path))
        #expect(errors[1].contains(anotherBad.path))
        #expect(output.count == (query == "Foo" ? 2 : 1))
        #expect(output.allSatisfy { !$0.hasPrefix("error:") })
        if query == "Foo" { #expect(output[1].contains("\t_Foo\tFoo")) }
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
        var output: [String] = []
        var errors: [String] = []
        let status = try runPrivateHeaderKitSearchCommand(
            .init(query: "Foo", directory: root.path, exact: false),
            outputLogger: { output.append($0) }, errorLogger: { errors.append($0) }
        )
        #expect(status == 2)
        #expect(output.count == 2)
        #expect(errors.contains { $0.contains(unreadable.path) })
        #expect(!errors.contains { $0.contains("no .symbols.tsv files found") })
    }

    @Test func missingRootReportsTraversalFailureInsteadOfMissingLists() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Missing")
        var errors: [String] = []
        let status = try runPrivateHeaderKitSearchCommand(
            .init(query: "Foo", directory: missing.path, exact: false),
            outputLogger: { _ in Issue.record("unexpected output for a missing root") },
            errorLogger: { errors.append($0) }
        )
        #expect(status == 2)
        #expect(errors.contains { $0.contains(missing.path) })
        #expect(!errors.contains { $0.contains("no .symbols.tsv files found") })
    }

    @Test func cancellationAfterTheFinalResultIsNotReportedAsSearchSuccess() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeList(to: root.appendingPathComponent("Foo.symbols.tsv"))
        let task = Task {
            try runPrivateHeaderKitSearchCommand(
                .init(query: "Foo", directory: root.path, exact: false),
                outputLogger: { line in
                    if line.contains("\t_Foo\tFoo") { withUnsafeCurrentTask { $0?.cancel() } }
                },
                errorLogger: { _ in Issue.record("cancellation was reported as a file error") }
            )
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
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
