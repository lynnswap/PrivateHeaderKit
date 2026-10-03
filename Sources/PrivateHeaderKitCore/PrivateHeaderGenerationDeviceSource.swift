import Foundation
import PrivateHeaderKitHelperProtocol

extension PrivateHeaderGeneration {
  /// Metadata and a target catalog collected by the helper on the source device.
  package struct DeviceSourceSnapshot: Codable, Hashable, Sendable {
    package let schemaVersion: Int
    package let producerVersion: String
    package let version: String
    package let build: String
    package let architecture: String
    package let cacheUUID: UUID
    package let metadataIsSeed: Bool
    private let catalogData: Data

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

    package func source() throws -> Source {
      guard schemaVersion == 1 else {
        throw CocoaError(.coderReadCorrupt, userInfo: [
          NSLocalizedDescriptionKey: "unsupported device source schema \(schemaVersion)"
        ])
      }
      return try Source(
        platform: .iOS, version: version, build: build, metadataIsSeed: metadataIsSeed,
        imageVariant: .iPhoneOS(architecture: architecture, cacheUUID: cacheUUID)
      )
    }

    func catalog(includeNestedChildren: Bool = true) throws -> TargetDiscovery.Catalog {
      _ = try source()
      let catalog = try JSONDecoder().decode(TargetDiscovery.Catalog.self, from: catalogData)
      for target in catalog.allExecutionTargets {
        _ = try ArtifactPath(target.artifactRoot.rawValue)
      }
      if includeNestedChildren { return catalog }
      return TargetDiscovery.Catalog(groups: catalog.groups.compactMap { group in
        guard let primary = group.primaryTarget else { return nil }
        return .init(selectionCandidate: group.selectionCandidate, primaryTarget: primary, childTargets: [])
      })
    }
  }
}
