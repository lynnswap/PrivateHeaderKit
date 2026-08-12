import Foundation

#if canImport(Darwin)
import Darwin
#endif

struct InstallPathGuidance {
    private enum LoginProfile {
        case existing(URL, appendable: Bool)
        case creatable(URL)
        case unavailable

        var url: URL? {
            switch self {
            case .existing(let url, _), .creatable(let url):
                url
            case .unavailable:
                nil
            }
        }

        var isAppendable: Bool {
            switch self {
            case .existing(_, appendable: let appendable):
                appendable
            case .creatable:
                true
            case .unavailable:
                false
            }
        }
    }

    let commandDirectory: URL
    let environment: [String: String]
    let fileManager: FileManager

    func messages() -> [String] {
        guard !commandDirectoryIsOnPATH else { return [] }

        let directoryPath = commandDirectory.path
        guard !directoryPath.contains(":"), !directoryPath.contains(where: \.isNewline) else {
            return [
                "",
                "PrivateHeaderKit is installed, but its command directory cannot be represented safely in PATH.",
                "",
                "Next steps:",
                "  Run the command using the path printed above, or reinstall to a directory without ':' or newlines.",
            ]
        }

        guard let loginShell = loginShell() else {
            return [
                "",
                "PrivateHeaderKit is installed, but its command directory is not on your PATH.",
                "",
                "Next steps:",
                "  Add this directory to your login shell's PATH:",
                "    \(directoryPath)",
                "",
                "Then run:",
                "  privateheaderkit",
            ]
        }

        let exportLine = "export PATH=\(shellQuote(directoryPath)):\"$PATH\""
        var result = [
            "",
            "PrivateHeaderKit is installed, but its command directory is not on your PATH.",
            "",
            "Next steps:",
        ]

        if case .existing(let profileURL, _) = loginShell.profile,
           profileContains(exportLine, at: profileURL)
        {
            result.append("  \(profileURL.path) already contains the PATH entry.")
            result.append("  Open a new terminal, or use PrivateHeaderKit in this shell:")
        } else if loginShell.profile.isAppendable,
                  let profileURL = loginShell.profile.url
        {
            let appendCommand = "printf '\\n%s\\n' \(shellQuote(exportLine)) >> \(shellQuote(profileURL.path))"
            result.append("  Add PrivateHeaderKit to future \(loginShell.name) sessions:")
            result.append("    \(appendCommand)")
            result.append("")
            result.append("  Use PrivateHeaderKit in this shell:")
        } else {
            result.append("  Add the command directory to a writable \(loginShell.name) login profile.")
            result.append("")
            result.append("  Use PrivateHeaderKit in this shell:")
        }

        result.append("    \(exportLine)")
        result.append("")
        result.append("Then run:")
        result.append("  privateheaderkit")
        return result
    }

    private var commandDirectoryIsOnPATH: Bool {
        guard let path = environment["PATH"] else { return false }
        let installedPath = commandDirectory.standardizedFileURL.path
        return path.split(separator: ":", omittingEmptySubsequences: false).contains { entry in
            canonicalPATHEntry(String(entry)) == installedPath
        }
    }

    private func canonicalPATHEntry(_ entry: String) -> String {
        let url: URL
        if entry.isEmpty {
            url = URL(
                fileURLWithPath: fileManager.currentDirectoryPath,
                isDirectory: true
            )
        } else {
            url = URL(fileURLWithPath: entry, isDirectory: true)
        }
        let standardized = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path) else {
            return standardized.path
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func loginShell() -> (name: String, profile: LoginProfile)? {
        guard let shellPath = nonEmpty(environment["SHELL"]),
              let home = nonEmpty(environment["HOME"])
        else {
            return nil
        }

        let shellName = (shellPath as NSString).lastPathComponent
        switch shellName {
        case "zsh":
            let profileRoot = nonEmpty(environment["ZDOTDIR"]) ?? home
            let profileURL = URL(fileURLWithPath: profileRoot, isDirectory: true)
                .appendingPathComponent(".zprofile", isDirectory: false)
            return (shellName, classifyProfile(profileURL))
        case "bash":
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            let candidates = [".bash_profile", ".bash_login", ".profile"].map {
                homeURL.appendingPathComponent($0, isDirectory: false)
            }
            if let existingProfile = candidates.first(where: isReadableRegularFile) {
                return (shellName, classifyProfile(existingProfile))
            }
            if candidates.allSatisfy(isAbsent) {
                return (shellName, classifyProfile(candidates[0]))
            }
            return (shellName, .unavailable)
        default:
            return nil
        }
    }

    private func profileContains(_ line: String, at url: URL) -> Bool {
        guard let data = fileManager.contents(atPath: url.path),
              let contents = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return contents.split(whereSeparator: \.isNewline).contains { $0 == line }
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return false
        }
        return fileManager.isReadableFile(atPath: resolvedURL.path)
    }

    private func classifyProfile(_ url: URL) -> LoginProfile {
        if isReadableRegularFile(url) {
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            return .existing(
                url,
                appendable: fileManager.isWritableFile(atPath: resolvedURL.path)
            )
        }
        if isAbsent(url), isWritableDirectory(url.deletingLastPathComponent()) {
            return .creatable(url)
        }
        return .unavailable
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: resolvedURL.path),
              attributes[.type] as? FileAttributeType == .typeDirectory
        else {
            return false
        }
        return fileManager.isWritableFile(atPath: resolvedURL.path)
    }

    private func isAbsent(_ url: URL) -> Bool {
        #if canImport(Darwin)
        var metadata = stat()
        let result = url.path.withCString { Darwin.lstat($0, &metadata) }
        return result != 0 && errno == ENOENT
        #else
        return !fileManager.fileExists(atPath: url.path)
        #endif
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
