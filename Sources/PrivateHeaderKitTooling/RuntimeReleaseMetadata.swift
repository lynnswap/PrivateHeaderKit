import Foundation

package enum RuntimeRootLayout: Sendable {
    case simulator
    case macOS
}

package enum RuntimeReleaseMetadata {
    private struct RestoreVersion: Decodable {
        let isSeed: Bool?

        private enum CodingKeys: String, CodingKey {
            case isSeed = "IsSeed"
        }
    }

    package static func isSeed(
        in systemRoot: URL,
        layout: RuntimeRootLayout
    ) throws -> Bool {
        guard systemRoot.isFileURL else {
            throw ToolingError.message(
                "runtime system root is not a file URL: \(systemRoot.absoluteString)"
            )
        }
        let metadataURL: URL
        switch layout {
        case .simulator:
            metadataURL = systemRoot.appendingPathComponent(
                "RestoreVersion.plist",
                isDirectory: false
            )
        case .macOS:
            metadataURL = systemRoot.appendingPathComponent(
                "System/Library/CoreServices/RestoreVersion.plist",
                isDirectory: false
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: metadataURL)
        } catch {
            throw ToolingError.message(
                "failed to read runtime release metadata at \(metadataURL.path): \(error)"
            )
        }
        do {
            return try PropertyListDecoder().decode(RestoreVersion.self, from: data).isSeed ?? false
        } catch {
            throw ToolingError.message(
                "failed to decode runtime release metadata at \(metadataURL.path): \(error)"
            )
        }
    }
}
