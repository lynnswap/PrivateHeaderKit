import Foundation

package enum ExecutableResolution {
    package static func resolveBundleExecutableURL(
        _ bundleURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        bundleURLs: (URL) -> (bundleURL: URL, executableURL: URL)? = {
            guard let bundle = Bundle(url: $0), let executableURL = bundle.executableURL else {
                return nil
            }
            return (bundle.bundleURL, executableURL)
        }
    ) -> URL? {
        if let resolved = bundleURLs(bundleURL) {
            // `Bundle(url:)` may resolve the caller's URL to a renamed symlink target or a
            // Cryptex path. Derive the suffix from the URLs owned by that same Bundle lookup so
            // output identity remains rooted at the caller-supplied bundle URL.
            let suffixComponents = Self.relativePathComponents(
                of: resolved.executableURL,
                inside: resolved.bundleURL
            ) ?? Self.relativePathComponents(
                of: resolved.executableURL.resolvingSymlinksInPath(),
                inside: resolved.bundleURL.resolvingSymlinksInPath()
            )
            if let suffixComponents {
                var rebased = bundleURL
                for component in suffixComponents {
                    rebased.appendPathComponent(component)
                }
                if fileExists(rebased.path) {
                    return rebased
                }
            }
            return resolved.executableURL
        }

        let baseName = bundleURL.deletingPathExtension().lastPathComponent
        let candidates = [
            bundleURL.appendingPathComponent(baseName),
            bundleURL.appendingPathComponent("Versions/Current/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/A/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/B/\(baseName)"),
            bundleURL.appendingPathComponent("Versions/C/\(baseName)"),
        ]
        for candidate in candidates where fileExists(candidate.path) {
            return candidate
        }

        // Some system bundles (especially on modern macOS) only expose a dyld shared-cache image
        // path while the on-disk executable symlink is intentionally absent/broken. Return the
        // canonical in-bundle executable path so shared-cache lookup can still resolve the image.
        return bundleURL.appendingPathComponent(baseName)
    }

    private static func relativePathComponents(of url: URL, inside directoryURL: URL) -> [String]? {
        let directoryComponents = directoryURL.standardizedFileURL.pathComponents
        let pathComponents = url.standardizedFileURL.pathComponents
        guard
            pathComponents.count > directoryComponents.count,
            pathComponents.starts(with: directoryComponents)
        else {
            return nil
        }
        return Array(pathComponents.dropFirst(directoryComponents.count))
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
