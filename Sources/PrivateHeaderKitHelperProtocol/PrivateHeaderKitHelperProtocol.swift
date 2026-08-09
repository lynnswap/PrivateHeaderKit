import Foundation

package enum PrivateHeaderKitHelperCommand: String, Sendable {
    case rawDump = "__raw-dump"
    case sharedCacheInventory = "__shared-cache-inventory"
}

package struct PrivateHeaderKitSharedCacheInventory: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let cacheUUID: UUID
    package let imagePaths: [String]

    package init(cacheUUID: UUID, imagePaths: [String]) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.cacheUUID = cacheUUID
        self.imagePaths = try Self.validatedImagePaths(imagePaths)
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(
                expected: Self.currentSchemaVersion,
                actual: schemaVersion
            )
        }

        self.schemaVersion = schemaVersion
        self.cacheUUID = try container.decode(UUID.self, forKey: .cacheUUID)
        self.imagePaths = try Self.validatedImagePaths(
            container.decode([String].self, forKey: .imagePaths)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(cacheUUID, forKey: .cacheUUID)
        try container.encode(imagePaths, forKey: .imagePaths)
    }

    private static func validatedImagePaths(_ paths: [String]) throws -> [String] {
        let validated = try paths.map { path in
            guard isAbsoluteLogicalPath(path) else {
                throw ValidationError.invalidImagePath(path)
            }
            return path
        }
        return Array(Set(validated)).sorted()
    }

    private static func isAbsoluteLogicalPath(_ path: String) -> Bool {
        guard path.first == "/", path.count > 1 else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.dropFirst().contains { component in
            component.isEmpty || component == "." || component == ".."
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cacheUUID
        case imagePaths
    }
}

package extension PrivateHeaderKitSharedCacheInventory {
    enum ValidationError: Error, Equatable, CustomStringConvertible, Sendable {
        case unsupportedSchemaVersion(expected: Int, actual: Int)
        case invalidImagePath(String)

        package var description: String {
            switch self {
            case .unsupportedSchemaVersion(let expected, let actual):
                "unsupported shared-cache inventory schema version \(actual); expected \(expected)"
            case .invalidImagePath(let path):
                "shared-cache image path must be an absolute logical path: \(path)"
            }
        }
    }
}
