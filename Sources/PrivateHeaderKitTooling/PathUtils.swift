import Foundation

public enum PathUtils {
    public static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    public static func findRepositoryRoot(startingAt start: URL, fileManager: FileManager = .default) -> URL? {
        var current = start.standardizedFileURL
        while current.path != "/" {
            if fileManager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

}
