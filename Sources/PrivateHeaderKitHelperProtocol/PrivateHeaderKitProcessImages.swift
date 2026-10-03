import Foundation

package struct PrivateHeaderKitProcessImage: Codable, Equatable, Sendable {
    package let loadAddress: UInt64
    package let path: String
    package let uuid: UUID
    package let cpuType: Int32
    package let cpuSubtype: Int32
    package let fileType: UInt32

    package init(
        loadAddress: UInt64, path: String, uuid: UUID,
        cpuType: Int32, cpuSubtype: Int32, fileType: UInt32
    ) {
        self.loadAddress = loadAddress
        self.path = path
        self.uuid = uuid
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.fileType = fileType
    }
}

package struct PrivateHeaderKitProcessImageFailure: Codable, Equatable, Sendable {
    package let loadAddress: UInt64
    package let path: String?
    package let error: String

    package init(loadAddress: UInt64, path: String?, error: String) {
        self.loadAddress = loadAddress
        self.path = path
        self.error = error
    }
}

package struct PrivateHeaderKitProcessImageInventory: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let producerVersion: String
    package let processIdentifier: Int32
    package let images: [PrivateHeaderKitProcessImage]
    package let failures: [PrivateHeaderKitProcessImageFailure]

    package init(
        processIdentifier: Int32,
        images: [PrivateHeaderKitProcessImage],
        failures: [PrivateHeaderKitProcessImageFailure],
        producerVersion: String = PrivateHeaderKitBuildInfo.version
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = try PrivateHeaderKitProducerVersion.validated(producerVersion)
        self.processIdentifier = processIdentifier
        self.images = images
        self.failures = failures
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
        processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        images = try container.decode([PrivateHeaderKitProcessImage].self, forKey: .images)
        failures = try container.decode([PrivateHeaderKitProcessImageFailure].self, forKey: .failures)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, producerVersion, processIdentifier, images, failures
    }
}

package struct PrivateHeaderKitRecoveredProcessImage: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let producerVersion: String
    package let processIdentifier: Int32
    package let image: PrivateHeaderKitProcessImage
    package let outputPath: String
    package let encryptedBytesRecovered: UInt64

    package init(
        processIdentifier: Int32, image: PrivateHeaderKitProcessImage,
        outputPath: String, encryptedBytesRecovered: UInt64,
        producerVersion: String = PrivateHeaderKitBuildInfo.version
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.producerVersion = try PrivateHeaderKitProducerVersion.validated(producerVersion)
        self.processIdentifier = processIdentifier
        self.image = image
        self.outputPath = outputPath
        self.encryptedBytesRecovered = encryptedBytesRecovered
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
        processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        image = try container.decode(PrivateHeaderKitProcessImage.self, forKey: .image)
        outputPath = try container.decode(String.self, forKey: .outputPath)
        encryptedBytesRecovered = try container.decode(UInt64.self, forKey: .encryptedBytesRecovered)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, producerVersion, processIdentifier, image, outputPath, encryptedBytesRecovered
    }
}

package enum PrivateHeaderKitProcessImageReportError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}
