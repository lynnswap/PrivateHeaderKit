import Foundation
import PrivateHeaderKitHelperProtocol

/// Metadata and a target catalog collected by the helper on the source device.
package struct DeviceSourceSnapshot: Codable, Hashable, Sendable {
  package let schemaVersion: Int
  package let producerVersion: String
  package let version: String
  package let build: String
  package let architecture: String
  package let cacheUUID: UUID
  package let metadataIsSeed: Bool
  /// The JSON encoding of the `TargetDiscovery.Catalog` found on the device.
  package let catalogData: Data

  package static func collect(
    systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true),
    architecture: String,
    inventory: PrivateHeaderKitSharedCacheInventory
  ) throws -> Self {
    let systemVersion = try PrivateHeaderKitOperatingSystemVersion.collect(systemRoot: systemRoot)
    let catalog = try TargetDiscovery.discover(
      in: systemRoot, sharedCacheImagePaths: inventory.imagePaths
    )
    return Self(
      schemaVersion: 1,
      producerVersion: PrivateHeaderKitBuildInfo.version,
      version: systemVersion.version,
      build: systemVersion.build,
      architecture: architecture,
      cacheUUID: inventory.cacheUUID,
      metadataIsSeed: systemVersion.metadataIsSeed,
      catalogData: try JSONEncoder().encode(catalog)
    )
  }
}
