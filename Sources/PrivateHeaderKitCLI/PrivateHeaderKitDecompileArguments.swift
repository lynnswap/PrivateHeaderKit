import ArgumentParser
import Foundation

struct PrivateHeaderKitDecompileCommand: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case binary(String)
        case sharedCache(path: String, image: String)
    }

    let source: Source
    let symbol: String
    let ghidraHome: String?
    let ipsw: String
    let processor: String?
    let timeout: Int32
    let outputPath: String?
}

struct PrivateHeaderKitDecompileArguments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decompile",
        abstract: "Decompile one named function locally with Ghidra."
    )

    @Option(help: "Mach-O file containing the function.") var binary: String?
    @Option(help: "Dyld shared-cache file to extract an image from.") var sharedCache: String?
    @Option(help: "Full logical image path in --shared-cache.") var image: String?
    @Option(help: "Original symbol name, as shown by symbol search.") var symbol: String
    @Option(help: "Ghidra installation directory; defaults to GHIDRA_HOME or analyzeHeadless on PATH.")
    var ghidraHome: String?
    @Option(help: "ipsw executable used only for shared-cache extraction.") var ipsw = "ipsw"
    @Option(help: "Ghidra processor language ID, to select a slice in a universal binary.")
    var processor: String?
    @Option(help: "Time limit in seconds for analysis and decompilation, separately.")
    var timeout: Int32 = 120
    @Option(name: .customLong("output"), help: "Write pseudocode to a new file instead of standard output.")
    var outputPath: String?

    mutating func validate() throws { _ = try command() }

    func command() throws -> PrivateHeaderKitDecompileCommand {
        guard !symbol.isEmpty else { throw ValidationError("--symbol must not be empty") }
        guard timeout > 0 else { throw ValidationError("--timeout must be greater than zero") }
        let source: PrivateHeaderKitDecompileCommand.Source
        switch (binary, sharedCache, image) {
        case (.some(let binary), nil, nil) where !binary.isEmpty:
            source = .binary(binary)
        case (nil, .some(let cache), .some(let image)) where !cache.isEmpty && image.hasPrefix("/"):
            source = .sharedCache(path: cache, image: image)
        default:
            throw ValidationError("Specify either --binary, or --shared-cache with a full --image path")
        }
        return .init(source: source, symbol: symbol, ghidraHome: ghidraHome, ipsw: ipsw,
                     processor: processor, timeout: timeout, outputPath: outputPath)
    }
}
