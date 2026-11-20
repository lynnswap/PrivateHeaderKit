import ArgumentParser
import Foundation
import PrivateHeaderKitHelperProtocol

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

    var options: SearchCommand.Options {
        .init(query: query, directory: directory, exact: exact)
    }
}

/// Searches the symbol lists under a generated header directory.
struct SearchCommand {
    struct Options: Equatable, Sendable {
        let query: String
        let directory: String
        let exact: Bool
    }

    let options: Options
    let console: Console

    /// Returns 0 when a symbol matched, 1 when none did, and 2 when a list could not be read.
    func run() throws -> Int32 {
        try Task.checkCancellation()
        let directory = URL(fileURLWithPath: options.directory, isDirectory: true).standardizedFileURL
        var hadErrors = false
        func reportFailure(_ message: String) {
            hadErrors = true
            console.error("error: \(message)")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                reportFailure("could not enumerate \(url.path): \(error)")
                return !Task.isCancelled
            }
        ) else {
            try Task.checkCancellation()
            if !hadErrors { reportFailure("could not enumerate directory \(directory.path)") }
            return 2
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.lastPathComponent.hasSuffix(".symbols.tsv") else { continue }
            do {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files.append(url)
                }
            } catch {
                try Task.checkCancellation()
                reportFailure("could not inspect \(url.path): \(error)")
            }
        }
        try Task.checkCancellation()
        guard !files.isEmpty else {
            if !hadErrors {
                reportFailure("no .symbols.tsv files found in \(directory.path); generate the requested targets first")
            }
            return 2
        }

        console.output("file\timage\tvisibility\tname\tdemangled_name")
        var found = false
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let list: PrivateHeaderKitSymbolList
            do {
                list = try PrivateHeaderKitSymbolList(tsv: String(contentsOf: file, encoding: .utf8))
            } catch {
                try Task.checkCancellation()
                reportFailure("could not read symbol list \(file.path): \(error)")
                continue
            }
            for symbol in list.symbols {
                try Task.checkCancellation()
                let names = [symbol.name, symbol.demangledName]
                let matches = options.exact
                    ? names.contains(options.query)
                    : names.contains { $0.range(of: options.query, options: .caseInsensitive) != nil }
                guard matches else { continue }
                found = true
                console.output([
                    file.path,
                    list.imagePath,
                    symbol.visibility.rawValue,
                    symbol.name,
                    symbol.demangledName,
                ].map(PrivateHeaderKitSymbolList.escape).joined(separator: "\t"))
            }
        }
        try Task.checkCancellation()
        return hadErrors ? 2 : (found ? 0 : 1)
    }
}
