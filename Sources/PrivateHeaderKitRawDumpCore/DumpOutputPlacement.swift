import Foundation
import PrivateHeaderKitExecutableResolution

struct DumpOutputPlacement {
    let identity: ExecutableResolution.OutputIdentity
    let directory: URL
}

func outputPlacement(
    for executable: ExecutableResolution,
    outputRoot: URL,
    options: DumpOptions,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> DumpOutputPlacement {
    let identity = options.logicalImagePath.map { ExecutableResolution.OutputIdentity.image(URL(fileURLWithPath: $0)) } ?? logicalOutputIdentity(
        executable.outputIdentity,
        environment: environment
    )
    return DumpOutputPlacement(
        identity: identity,
        directory: writeDirectory(for: identity, outputRoot: outputRoot, options: options)
    )
}

private func logicalOutputIdentity(
    _ outputIdentity: ExecutableResolution.OutputIdentity,
    environment: [String: String]
) -> ExecutableResolution.OutputIdentity {
    switch outputIdentity {
    case .image(let url):
        .image(
            URL(
                fileURLWithPath: stripRuntimeRoot(from: url.path, environment: environment)
            )
        )
    case .bundle(let url):
        .bundle(
            URL(
                fileURLWithPath: stripRuntimeRoot(from: url.path, environment: environment),
                isDirectory: true
            )
        )
    }
}

extension ExecutableResolution.OutputIdentity {
    var url: URL {
        switch self {
        case .image(let url), .bundle(let url): url
        }
    }
}

func writeDirectory(
    for outputIdentity: ExecutableResolution.OutputIdentity,
    outputRoot: URL,
    options: DumpOptions
) -> URL {
    guard options.buildOriginalDirs else { return outputRoot }

    let target: (url: URL, isBundle: Bool)
    switch outputIdentity {
    case .bundle(let bundleURL):
        target = (bundleURL, true)
    case .image(let imageURL):
        let parentURL = imageURL.deletingLastPathComponent()
        if supportedBundlePathExtensions.contains(parentURL.pathExtension.lowercased()) {
            target = (parentURL, true)
        } else {
            target = (imageURL, false)
        }
    }
    var fullPath = outputRoot.path + target.url.path
    if target.isBundle && options.addHeadersFolder {
        fullPath += "/Headers"
    }
    fullPath = normalizePath(fullPath)
    return URL(fileURLWithPath: fullPath)
}

func normalizePath(_ path: String) -> String {
    var normalized = path
    while normalized.contains("//") {
        normalized = normalized.replacingOccurrences(of: "//", with: "/")
    }
    return normalized
}

private let maxPathComponentBytes = 255
private let truncatedNameHashLength = 16
let caseInsensitiveFileNameLocale = Locale(identifier: "en_US_POSIX")

func safeFileName(baseName: String, suffix: String = "", extension ext: String) -> String {
    let normalizedExt = ext.isEmpty ? "" : (ext.hasPrefix(".") ? ext : ".\(ext)")
    let maxBaseBytes = max(0, maxPathComponentBytes - suffix.utf8.count - normalizedExt.utf8.count)
    let normalizedBase: String
    if baseName.utf8.count <= maxBaseBytes {
        normalizedBase = baseName
    } else {
        let hash = stableHashHex(baseName)
        let truncationSuffix = "~\(hash)"
        let maxPrefixBytes = max(0, maxBaseBytes - truncationSuffix.utf8.count)
        let prefix = truncateToByteCount(baseName, maxBytes: maxPrefixBytes)
        normalizedBase = prefix + truncationSuffix
    }
    return normalizedBase + suffix + normalizedExt
}

private func truncateToByteCount(_ value: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    if value.utf8.count <= maxBytes {
        return value
    }
    var used = 0
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars {
        let size = scalar.utf8.count
        if used + size > maxBytes {
            break
        }
        scalars.append(scalar)
        used += size
    }
    return String(scalars)
}

func stableHashHex(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    let hex = String(hash, radix: 16)
    if hex.count >= truncatedNameHashLength {
        return hex
    }
    return String(repeating: "0", count: truncatedNameHashLength - hex.count) + hex
}

func writeIfNeeded(
    text: String,
    to url: URL,
    options: DumpOptions,
    fileManager: FileManager
) throws {
    if options.skipExisting && fileManager.fileExists(atPath: url.path) {
        return
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
}
