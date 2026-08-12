import Foundation

#if canImport(Darwin)
import Darwin
#endif

// PrivateHeaderKit's pre-cohort installer reserved these exact product names in
// the selected command directory. Keep the names explicit and remove by path:
// legacy installs have no receipt, and content heuristics cannot recognize every
// locally built version without leaving the retired commands executable.
enum ObsoletePublicCommand: String, CaseIterable, Sendable {
    case privateHeaderKitDump = "privateheaderkit-dump"
    case headerDump = "headerdump"
    case headerDumpSimulator = "headerdump-sim"
}

extension InstallLayout {
    func url(for command: ObsoletePublicCommand) -> URL {
        binDir.appendingPathComponent(command.rawValue, isDirectory: false)
    }
}

extension VersionCohortInstaller {
    func validateObsoleteCommandCleanupTargets() throws {
        for command in ObsoletePublicCommand.allCases {
            let url = layout.url(for: command)
            switch try fileSystemItemKind(at: url, fileManager: fileManager) {
            case .absent, .regularFile, .symbolicLink:
                continue
            case .directory, .other:
                throw InstallError.message(
                    "obsolete command path is not a removable file: \(url.path)"
                )
            }
        }
    }

    func removeObsoletePublicCommands() throws -> [URL] {
        var removed: [URL] = []
        for command in ObsoletePublicCommand.allCases {
            let url = layout.url(for: command)
#if canImport(Darwin)
            let result = url.path.withCString { path in
                Darwin.unlink(path)
            }
            if result == 0 {
                removed.append(url)
                continue
            }
            let failure = errno
            if failure == ENOENT {
                continue
            }
            throw InstallError.message(
                "new cohort is active, but failed to remove obsolete command at \(url.path): errno \(failure)"
            )
#else
            throw InstallError.message(
                "obsolete command cleanup is unavailable on this platform: \(url.path)"
            )
#endif
        }
        return removed
    }
}
