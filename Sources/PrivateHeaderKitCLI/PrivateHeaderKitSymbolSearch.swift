import ArgumentParser
import Foundation
import PrivateHeaderKitHelperProtocol

struct PrivateHeaderKitSearchCommand: Equatable, Sendable {
    let query: String
    let directory: String
    let exact: Bool
}

struct PrivateHeaderKitSearchArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search generated symbol names without loading a runtime."
    )

    @Argument(help: "Literal text to find in original or demangled symbol names.")
    var query: String

    @Option(name: .customLong("in"), help: "Generated header directory or a parent directory to search.")
    var directory: String

    @Flag(help: "Match a complete, case-sensitive original or demangled name.")
    var exact = false

    mutating func validate() throws {
        guard !query.isEmpty else { throw ValidationError("Search text must not be empty") }
    }

    var command: PrivateHeaderKitSearchCommand {
        .init(query: query, directory: directory, exact: exact)
    }
}

enum PrivateHeaderKitSymbolSearchError: Error, CustomStringConvertible {
    case noLists(String)
    case invalidList(path: String, reason: String)

    var description: String {
        switch self {
        case .noLists(let directory):
            "no .symbols.tsv files found in \(directory); generate the targets with this version using --fresh"
        case .invalidList(let path, let reason):
            "could not read symbol list \(path): \(reason)"
        }
    }
}

func runPrivateHeaderKitSearchCommand(
    _ command: PrivateHeaderKitSearchCommand,
    outputLogger: (String) -> Void
) throws -> Int32 {
    let directory = URL(fileURLWithPath: command.directory, isDirectory: true).standardizedFileURL
    var enumerationError: (any Error)?
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles],
        errorHandler: { _, error in
            enumerationError = error
            return false
        }
    ) else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
    }
    var files: [URL] = []
    for case let url as URL in enumerator {
        try Task.checkCancellation()
        guard url.lastPathComponent.hasSuffix(".symbols.tsv"),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        files.append(url)
    }
    if let enumerationError { throw enumerationError }
    guard !files.isEmpty else { throw PrivateHeaderKitSymbolSearchError.noLists(directory.path) }

    outputLogger("file\timage\tvisibility\tname\tdemangled_name")
    var found = false
    for file in files.sorted(by: { $0.path < $1.path }) {
        try Task.checkCancellation()
        let list: PrivateHeaderKitSymbolList
        do {
            list = try PrivateHeaderKitSymbolList(tsv: String(contentsOf: file, encoding: .utf8))
        } catch {
            throw PrivateHeaderKitSymbolSearchError.invalidList(path: file.path, reason: String(describing: error))
        }
        for symbol in list.symbols {
            try Task.checkCancellation()
            let names = [symbol.name, symbol.demangledName]
            let matches = command.exact
                ? names.contains(command.query)
                : names.contains { $0.range(of: command.query, options: .caseInsensitive) != nil }
            guard matches else { continue }
            found = true
            outputLogger([
                file.path,
                list.imagePath,
                symbol.visibility.rawValue,
                symbol.name,
                symbol.demangledName,
            ].map(PrivateHeaderKitSymbolList.escape).joined(separator: "\t"))
        }
    }
    return found ? 0 : 1
}
