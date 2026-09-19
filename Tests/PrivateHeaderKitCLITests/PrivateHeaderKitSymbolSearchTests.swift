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

    @Test func reportsMissingAndMalformedListsInsteadOfHidingReadFailures() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let command = PrivateHeaderKitSearchCommand(query: "anything", directory: root.path, exact: false)
        #expect(throws: PrivateHeaderKitSymbolSearchError.self) {
            try runPrivateHeaderKitSearchCommand(command, outputLogger: { _ in })
        }
        try "broken".write(to: root.appendingPathComponent("Foo.symbols.tsv"), atomically: true, encoding: .utf8)
        #expect(throws: PrivateHeaderKitSymbolSearchError.self) {
            try runPrivateHeaderKitSearchCommand(command, outputLogger: { _ in })
        }
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
