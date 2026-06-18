import Foundation
import PrivateHeaderKitTooling

public struct RecordedCommand: Equatable {
    public let command: [String]
    public let env: [String: String]?
    public let cwd: URL?

    public init(command: [String], env: [String: String]?, cwd: URL?) {
        self.command = command
        self.env = env
        self.cwd = cwd
    }
}

public final class RecordingCommandRunner: CommandRunning {
    public private(set) var captureCommands: [RecordedCommand] = []
    public private(set) var simpleCommands: [RecordedCommand] = []
    public private(set) var streamingCommands: [RecordedCommand] = []

    public var captureOutputs: [String: String] = [:]
    public var simpleHandler: (([String], [String: String]?, URL?) throws -> Void)?
    public var streamingHandler: (([String], [String: String]?, URL?) throws -> StreamingCommandResult)?

    public init() {}

    public func setCaptureOutput(_ output: String, for command: [String]) {
        captureOutputs[key(for: command)] = output
    }

    public func runCapture(_ command: [String], env: [String: String]?, cwd: URL?) throws -> String {
        captureCommands.append(RecordedCommand(command: command, env: env, cwd: cwd))
        guard let output = captureOutputs[key(for: command)] else {
            throw ToolingError.message("unexpected runCapture command: \(command.joined(separator: " "))")
        }
        return output
    }

    public func runSimple(_ command: [String], env: [String: String]?, cwd: URL?) throws {
        simpleCommands.append(RecordedCommand(command: command, env: env, cwd: cwd))
        try simpleHandler?(command, env, cwd)
    }

    public func runStreaming(_ command: [String], env: [String: String]?, cwd: URL?) throws -> StreamingCommandResult {
        streamingCommands.append(RecordedCommand(command: command, env: env, cwd: cwd))
        if let streamingHandler {
            return try streamingHandler(command, env, cwd)
        }
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }

    private func key(for command: [String]) -> String {
        command.joined(separator: "\u{1f}")
    }
}

public struct TestDirectories {
    public let root: URL
    public let runtimeRoot: URL
    public let outDir: URL
    public let stageDir: URL

    public init(root: URL) {
        self.root = root
        self.runtimeRoot = root.appendingPathComponent("RuntimeRoot", isDirectory: true)
        self.outDir = root.appendingPathComponent("Out", isDirectory: true)
        self.stageDir = root.appendingPathComponent(".tmp-stage", isDirectory: true)
    }

    public func create() throws {
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    public func createFramework(_ name: String, category: String = "Frameworks") throws -> URL {
        let url = runtimeRoot
            .appendingPathComponent("System/Library", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func createSystemLibraryBundle(_ relativePath: String) throws -> URL {
        let url = appending(relativePath, to: runtimeRoot.appendingPathComponent("System/Library", isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func createUsrLibDylib(_ name: String) throws -> URL {
        let url = runtimeRoot
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }
}

public func makeTemporaryTestDirectories() throws -> TestDirectories {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("PrivateHeaderKitTests-\(UUID().uuidString)", isDirectory: true)
    let dirs = TestDirectories(root: root)
    try dirs.create()
    return dirs
}

public final class HeaderdumpFixtureRunner {
    public private(set) var sourcePaths: [String] = []
    public var failingSourceSuffixes: Set<String>

    public init(failingSourceSuffixes: Set<String> = []) {
        self.failingSourceSuffixes = failingSourceSuffixes
    }

    public func handle(command: [String], env _: [String: String]?, cwd _: URL?) throws -> StreamingCommandResult {
        let parsed = try parseHeaderdumpCommand(command)
        sourcePaths.append(parsed.sourcePath)

        if failingSourceSuffixes.contains(where: { parsed.sourcePath.hasSuffix($0) }) {
            return StreamingCommandResult(
                status: 1,
                wasKilled: false,
                lastLines: ["simulated failure for \(parsed.sourcePath)"]
            )
        }

        let outputDir = outputDirectory(stageDir: parsed.stageDir, sourcePath: parsed.sourcePath)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try Data("// generated: \(parsed.sourcePath)\n".utf8)
            .write(to: outputDir.appendingPathComponent("Generated.h", isDirectory: false))
        return StreamingCommandResult(status: 0, wasKilled: false, lastLines: [])
    }

    private func parseHeaderdumpCommand(_ command: [String]) throws -> (stageDir: URL, sourcePath: String) {
        guard let outIndex = command.firstIndex(of: "-o"), outIndex + 1 < command.count else {
            throw ToolingError.message("headerdump command missing -o: \(command.joined(separator: " "))")
        }
        let stageDir = URL(fileURLWithPath: command[outIndex + 1], isDirectory: true)
        let tail = Array(command.dropFirst(outIndex + 2))
        let sourcePath: String
        if let recursiveIndex = tail.firstIndex(of: "-r"), recursiveIndex + 1 < tail.count {
            sourcePath = tail[recursiveIndex + 1]
        } else if let firstPath = tail.first(where: { !$0.hasPrefix("-") }) {
            sourcePath = firstPath
        } else {
            throw ToolingError.message("headerdump command missing source path: \(command.joined(separator: " "))")
        }
        return (stageDir, sourcePath)
    }

    private func outputDirectory(stageDir: URL, sourcePath: String) -> URL {
        if let range = sourcePath.range(of: "/System/Library/") {
            let relativePath = String(sourcePath[range.upperBound...])
            return appending(relativePath, to: stageDir.appendingPathComponent("System/Library", isDirectory: true))
                .appendingPathComponent("Headers", isDirectory: true)
        }

        if let range = sourcePath.range(of: "/usr/lib/") {
            let relativePath = String(sourcePath[range.upperBound...])
            return stageDir
                .appendingPathComponent("usr", isDirectory: true)
                .appendingPathComponent("lib", isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: true)
                .appendingPathComponent("Headers", isDirectory: true)
        }

        return stageDir
            .appendingPathComponent(sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")), isDirectory: true)
            .appendingPathComponent("Headers", isDirectory: true)
    }
}

private func appending(_ relativePath: String, to base: URL) -> URL {
    var url = base
    for part in relativePath.split(separator: "/").map(String.init) {
        url.appendPathComponent(part, isDirectory: true)
    }
    return url
}
