import Foundation

public enum Which {
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        findAll(name, environment: environment).first
    }

    static func findAll(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let fileManager = FileManager.default
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            if isExecutableRegularFile(at: url, fileManager: fileManager) {
                return [url]
            }
            return []
        }

        let pathValue = environment["PATH"] ?? ""
        var seenPaths: Set<String> = []
        var results: [URL] = []
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent(name)
            if seenPaths.insert(candidate.path).inserted,
               isExecutableRegularFile(at: candidate, fileManager: fileManager)
            {
                results.append(candidate)
            }
        }
        return results
    }

    private static func isExecutableRegularFile(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: url.path) else { return false }
        let resolvedURL = url.resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}
