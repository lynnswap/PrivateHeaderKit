import Foundation
import PrivateHeaderKitTooling
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum PrivateHeaderKitDecompilationError: Error, CustomStringConvertible {
    case ghidraUnavailable
    case toolFailed(String)
    case scriptFailed(String)
    case missingResult(String)
    case cleanupFailed(path: String, operationError: String?, cleanupError: String)

    var description: String {
        switch self {
        case .ghidraUnavailable:
            "Ghidra was not found; use --ghidra-home, set GHIDRA_HOME, or put analyzeHeadless on PATH"
        case .toolFailed(let message): message
        case .scriptFailed(let message): "Ghidra: \(message)"
        case .missingResult(let diagnostic): "Ghidra produced no pseudocode. \(diagnostic)"
        case .cleanupFailed(let path, let operationError, let cleanupError):
            [operationError, "could not remove decompilation workspace \(path): \(cleanupError)"]
                .compactMap { $0 }.joined(separator: "; ")
        }
    }
}

/// Decompiles one named function with a local Ghidra installation.
struct DecompileCommand: Sendable {
    enum Source: Equatable, Sendable {
        case binary(String)
        case sharedCache(path: String, image: String)
    }

    struct Options: Equatable, Sendable {
        let source: Source
        let symbol: String
        let ghidraHome: String?
        let ipsw: String
        let processor: String?
        let timeout: Int32
        let outputPath: String?
    }

    let options: Options
    let processRunner: any CommandRunning
    /// Pseudocode goes to standard output, and progress to standard error.
    let console: Console
    /// Supplies `GHIDRA_HOME` and `PATH`, and is passed on to Ghidra and `ipsw`.
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory

    func run() async throws -> Int32 {
        let code = try await pseudocode()
        if let path = options.outputPath {
            let url = URL(fileURLWithPath: path)
            try Data(code.utf8).write(to: url, options: .withoutOverwriting)
            console.output("Pseudocode: \(url.path)")
        } else {
            console.output(code)
        }
        return 0
    }

    /// Decompiles the function in a workspace under `temporaryDirectory` and removes the
    /// workspace again.
    func pseudocode() async throws -> String {
        let headless: String
        if let home = options.ghidraHome ?? environment["GHIDRA_HOME"] {
            headless = URL(fileURLWithPath: home).appendingPathComponent("support/analyzeHeadless").path
        } else if let executable = Which.find("analyzeHeadless", environment: environment) {
            headless = executable.path
        } else {
            throw PrivateHeaderKitDecompilationError.ghidraUnavailable
        }
        try Task.checkCancellation()
        let directory = try ghidraCanonicalDirectory(temporaryDirectory)
            .appendingPathComponent("privateheaderkit-decompile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let result: Result<String, any Error>
        do {
            result = .success(try await runGhidra(headless: headless, directory: directory))
        } catch {
            result = .failure(error)
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            let operationError: String?
            switch result {
            case .success: operationError = nil
            case .failure(let failure): operationError = String(describing: failure)
            }
            throw PrivateHeaderKitDecompilationError.cleanupFailed(
                path: directory.path, operationError: operationError, cleanupError: String(describing: error)
            )
        }
        return try result.get()
    }

    private func runGhidra(headless: String, directory: URL) async throws -> String {
        let binary: URL
        switch options.source {
        case .binary(let path):
            binary = URL(fileURLWithPath: path).standardizedFileURL
        case .sharedCache(let path, let image):
            let images = directory.appendingPathComponent("images")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: false)
            let ipsw = options.ipsw.contains("/")
                ? URL(fileURLWithPath: options.ipsw).standardizedFileURL.path : options.ipsw
            console.error("Extracting shared-cache image with ipsw...")
            let extraction = try await processRunner.runBuffered([
                ipsw, "dyld", "extract", URL(fileURLWithPath: path).standardizedFileURL.path,
                image, "--slide", "--objc", "--output", images.path,
                "--cache", directory.appendingPathComponent("symbols.a2s").path,
            ], env: environment, cwd: directory)
            guard extraction.status == 0, !extraction.wasKilled else {
                throw PrivateHeaderKitDecompilationError.toolFailed("shared-cache extraction failed: \(extraction.diagnosticText)")
            }
            binary = images.appendingPathComponent(URL(fileURLWithPath: image).lastPathComponent)
        }
        try Task.checkCancellation()
        try options.symbol.write(to: directory.appendingPathComponent("symbol.txt"), atomically: true, encoding: .utf8)
        try privateHeaderKitGhidraScript.write(to: directory.appendingPathComponent("PHKDecompile.java"), atomically: true, encoding: .utf8)
        var invocation = [
            headless, directory.path, "Analysis",
            "-import", binary.path,
            "-loader", "MachoLoader", "-loader-loadLibraries", "false",
            "-scriptPath", directory.path,
            "-preScript", "PHKDecompile.java", "select", directory.path,
            "-postScript", "PHKDecompile.java", "decompile", directory.path, String(options.timeout),
            "-analysisTimeoutPerFile", String(options.timeout),
            "-readOnly", "-deleteProject",
        ]
        if let processor = options.processor { invocation += ["-processor", processor] }
        console.error("Analyzing and decompiling with Ghidra...")
        let execution = try await processRunner.runBuffered(invocation, env: environment, cwd: directory)
        guard execution.status == 0, !execution.wasKilled else {
            throw PrivateHeaderKitDecompilationError.toolFailed("Ghidra failed: \(execution.diagnosticText)")
        }
        try Task.checkCancellation()
        let errorURL = directory.appendingPathComponent("error.txt")
        if FileManager.default.fileExists(atPath: errorURL.path) {
            throw PrivateHeaderKitDecompilationError.scriptFailed(try String(contentsOf: errorURL, encoding: .utf8))
        }
        let outputURL = directory.appendingPathComponent("code.c")
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PrivateHeaderKitDecompilationError.missingResult(execution.diagnosticText)
        }
        return try String(contentsOf: outputURL, encoding: .utf8)
    }
}

private func ghidraCanonicalDirectory(_ url: URL) throws -> URL {
    // Foundation preserves /var aliases on macOS; Ghidra's Java source-bundle
    // lookup needs the physical /private/var path returned by realpath.
    guard let path = realpath(url.path, nil) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
