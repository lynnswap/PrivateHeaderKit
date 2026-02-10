import Foundation

public enum Which {
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        if name.contains("/") {
            let url = URL(fileURLWithPath: name)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
            return nil
        }

        let pathValue = environment["PATH"] ?? ""
        for dir in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

