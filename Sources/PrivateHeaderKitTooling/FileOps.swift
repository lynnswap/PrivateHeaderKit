import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum FileOps {
    public static func buildStageDir(outDir: URL, pid: Int32 = getpid(), date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMddHHmmss"
        let token = "\(pid)-\(formatter.string(from: date))"
        return outDir.appendingPathComponent(".tmp-\(token)", isDirectory: true)
    }

    public static func normalizeFrameworkName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasSuffix(".framework") ? trimmed : "\(trimmed).framework"
    }

    public static func isSymlink(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }

    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    public static func tryRemoveEmpty(_ url: URL, fileManager: FileManager = .default) {
        // Match Python behavior: only remove if the directory is empty.
        _ = rmdir(url.path)
    }

    public static func tryRemoveFile(_ url: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: url)
    }

    public static func moveReplace(src: URL, dest: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: dest)
        try fileManager.moveItem(at: src, to: dest)
    }

    public static func mergeDirectories(src: URL, dest: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
        let entries = try fileManager.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for entry in entries {
            let target = dest.appendingPathComponent(entry.lastPathComponent, isDirectory: false)
            if isDirectory(entry) {
                try mergeDirectories(src: entry, dest: target, fileManager: fileManager)
                tryRemoveEmpty(entry, fileManager: fileManager)
            } else {
                if fileManager.fileExists(atPath: target.path) {
                    try? fileManager.removeItem(at: entry)
                } else {
                    try fileManager.moveItem(at: entry, to: target)
                }
            }
        }
        tryRemoveEmpty(src, fileManager: fileManager)
    }

    public static func resetStageDir(_ stageDir: URL, fileManager: FileManager = .default) throws {
        if fileManager.fileExists(atPath: stageDir.path) {
            try fileManager.removeItem(at: stageDir)
        }
        try fileManager.createDirectory(at: stageDir, withIntermediateDirectories: true)
    }

    public static func stageSystemLibraryRoots(stageDir: URL, runtimeRoot: String) -> [URL] {
        var roots: [URL] = [stageDir.appendingPathComponent("System/Library", isDirectory: true)]

        if runtimeRoot.hasPrefix("/") {
            let relative = String(runtimeRoot.dropFirst())
            roots.append(
                stageDir
                    .appendingPathComponent(relative, isDirectory: true)
                    .appendingPathComponent("System/Library", isDirectory: true)
            )
        }

        var unique: [URL] = []
        for root in roots where !unique.contains(root) {
            unique.append(root)
        }
        return unique
    }

    public static func normalizeFrameworkDirs(in categoryDir: URL, overwrite: Bool, fileManager: FileManager = .default) throws {
        guard isDirectory(categoryDir) else { return }
        let frameworkExt = ".framework"

        let entries = try fileManager.contentsOfDirectory(at: categoryDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])

        for entry in entries {
            if entry.lastPathComponent.hasSuffix(frameworkExt), isSymlink(entry) {
                try? fileManager.removeItem(at: entry)
            }
        }

        for entry in entries {
            if isSymlink(entry) { continue }
            guard isDirectory(entry) else { continue }
            let name = entry.lastPathComponent
            guard name.hasSuffix(frameworkExt) else { continue }
            let targetName = String(name.dropLast(frameworkExt.count))
            let target = categoryDir.appendingPathComponent(targetName, isDirectory: true)

            if fileManager.fileExists(atPath: target.path) {
                if isSymlink(target) {
                    try? fileManager.removeItem(at: target)
                }
            }

            if fileManager.fileExists(atPath: target.path) {
                if overwrite {
                    try? fileManager.removeItem(at: target)
                    try fileManager.moveItem(at: entry, to: target)
                } else {
                    try mergeDirectories(src: entry, dest: target, fileManager: fileManager)
                }
            } else {
                try fileManager.moveItem(at: entry, to: target)
            }
        }
    }

    public static func denormalizeFrameworkDirs(in categoryDir: URL, fileManager: FileManager = .default) throws {
        guard isDirectory(categoryDir) else { return }
        let frameworkExt = ".framework"

        let entries = try fileManager.contentsOfDirectory(at: categoryDir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])

        for entry in entries {
            if entry.lastPathComponent.hasSuffix(frameworkExt), isSymlink(entry) {
                try? fileManager.removeItem(at: entry)
            }
        }

        for entry in entries {
            if isSymlink(entry) { continue }
            guard isDirectory(entry) else { continue }
            let name = entry.lastPathComponent
            guard !name.hasSuffix(frameworkExt) else { continue }

            let dest = categoryDir.appendingPathComponent("\(name)\(frameworkExt)", isDirectory: true)

            if fileManager.fileExists(atPath: dest.path) {
                if isSymlink(dest) {
                    try? fileManager.removeItem(at: dest)
                }
            }

            if fileManager.fileExists(atPath: dest.path) {
                try mergeDirectories(src: entry, dest: dest, fileManager: fileManager)
            } else {
                try fileManager.moveItem(at: entry, to: dest)
            }
        }
    }
}
