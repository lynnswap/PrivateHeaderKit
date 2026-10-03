import Foundation

package struct PrivateHeaderKitOperatingSystemVersion: Codable, Hashable, Sendable {
    package let version: String
    package let build: String
    package let metadataIsSeed: Bool

    package init(version: String, build: String, metadataIsSeed: Bool) {
        self.version = version
        self.build = build
        self.metadataIsSeed = metadataIsSeed
    }
}

package struct PrivateHeaderKitRunningApplication: Codable, Equatable, Sendable {
    package let processIdentifier: Int32
    package let bundleIdentifier: String
    package let version: String?
    package let build: String?
    package let executableName: String
    package let mainImage: PrivateHeaderKitProcessImage

    package init(
        processIdentifier: Int32, bundleIdentifier: String, version: String?, build: String?,
        executableName: String, mainImage: PrivateHeaderKitProcessImage
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.executableName = executableName
        self.mainImage = mainImage
    }
}

package struct PrivateHeaderKitRunningApplicationReport: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1
    package let schemaVersion: Int
    package let producerVersion: String
    package let application: PrivateHeaderKitRunningApplication
    package let systemVersion: PrivateHeaderKitOperatingSystemVersion?

    package init(
        application: PrivateHeaderKitRunningApplication,
        systemVersion: PrivateHeaderKitOperatingSystemVersion? = nil,
        producerVersion: String = PrivateHeaderKitBuildInfo.version
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.producerVersion = try PrivateHeaderKitProducerVersion.validated(producerVersion)
        self.application = application
        self.systemVersion = systemVersion
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PrivateHeaderKitProcessImageReportError.unsupportedSchemaVersion(schemaVersion)
        }
        producerVersion = try PrivateHeaderKitProducerVersion.validated(
            container.decode(String.self, forKey: .producerVersion)
        )
        application = try container.decode(PrivateHeaderKitRunningApplication.self, forKey: .application)
        systemVersion = try container.decodeIfPresent(PrivateHeaderKitOperatingSystemVersion.self, forKey: .systemVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, producerVersion, application, systemVersion
    }
}
