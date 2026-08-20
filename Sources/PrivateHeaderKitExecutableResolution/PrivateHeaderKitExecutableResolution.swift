import Foundation

package struct ExecutableResolution {
    package enum OutputIdentity {
        case image(URL)
        case bundle(URL)
    }

    package let loadURL: URL
    package let outputIdentity: OutputIdentity

    package static func resolveBundle(
        _ bundleURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        bundleExecutableURL: (URL) -> URL? = { Bundle(url: $0)?.executableURL }
    ) -> Self {
        let baseName = bundleURL.deletingPathExtension().lastPathComponent
        let candidates = [
            bundleURL.appendingPathComponent(baseName),
            bundleURL.appendingPathComponent("Versions/Current/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/A/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/B/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/C/\(baseName)"),
        ]
        let loadURL = bundleExecutableURL(bundleURL)
            ?? candidates.first { fileExists($0.path) }
            // Some system bundles expose only a dyld shared-cache image while their canonical
            // on-disk executable is absent or broken. Loading may use a nonexistent URL, but
            // output identity remains the caller's bundle and must never depend on file existence.
            ?? bundleURL.appendingPathComponent(baseName)
        return Self(loadURL: loadURL, outputIdentity: .bundle(bundleURL))
    }

    package static func direct(_ url: URL) -> Self {
        Self(loadURL: url, outputIdentity: .image(url))
    }

    package static func normalizedCacheImagePaths(
        for path: String,
        environment: [String: String]
    ) -> [String] {
        var basePaths: [String] = [path]

        let rootCandidates = [
            environment["PH_RUNTIME_ROOT"],
            environment["DYLD_ROOT_PATH"],
            environment["SIMCTL_CHILD_DYLD_ROOT_PATH"],
        ].compactMap { $0 }

        for runtimeRoot in rootCandidates {
            let trimmedRoot = runtimeRoot.hasSuffix("/") ? String(runtimeRoot.dropLast()) : runtimeRoot
            if path.hasPrefix(trimmedRoot + "/") {
                let suffix = String(path.dropFirst(trimmedRoot.count))
                if !suffix.isEmpty {
                    basePaths.append(suffix)
                }
            }
        }

        if let range = path.range(of: "/System/Library/") {
            basePaths.append(String(path[range.lowerBound...]))
        }
        if let range = path.range(of: "/usr/lib/") {
            basePaths.append(String(path[range.lowerBound...]))
        }

        var results = basePaths
        for basePath in basePaths {
            // Shared-cache framework identities are commonly versioned even when the
            // filesystem-facing source path uses the unversioned bundle symlink. Restrict these
            // aliases to direct framework images so a nested child cannot match its parent's image.
            guard let frameworkRange = basePath.range(of: ".framework/"),
                  !basePath.contains(".framework/Versions/")
            else {
                continue
            }
            let frameworkRelativePath = basePath[frameworkRange.upperBound...]
            guard
                !frameworkRelativePath.isEmpty,
                !frameworkRelativePath.contains("/")
            else {
                continue
            }
            let frameworkPrefix = String(basePath[..<frameworkRange.upperBound])
            let imageName = String(frameworkRelativePath)
            results.append(frameworkPrefix + "Versions/Current/" + imageName)
            results.append(frameworkPrefix + "Versions/A/" + imageName)
            results.append(frameworkPrefix + "Versions/B/" + imageName)
            results.append(frameworkPrefix + "Versions/C/" + imageName)
        }

        var unique: [String] = []
        for item in results where !unique.contains(item) {
            unique.append(item)
        }
        return unique
    }
}
