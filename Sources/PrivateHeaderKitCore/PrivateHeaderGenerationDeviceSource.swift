import Foundation
import PrivateHeaderKitSourceInspection

extension DeviceSourceSnapshot {
  package func source() throws -> PrivateHeaderGeneration.Source {
    guard schemaVersion == 1 else {
      throw CocoaError(.coderReadCorrupt, userInfo: [
        NSLocalizedDescriptionKey: "unsupported device source schema \(schemaVersion)"
      ])
    }
    return try PrivateHeaderGeneration.Source(
      platform: .iOS, version: version, build: build, metadataIsSeed: metadataIsSeed,
      imageVariant: .iPhoneOS(architecture: architecture, cacheUUID: cacheUUID)
    )
  }

  func catalog() throws -> TargetDiscovery.Catalog {
    _ = try source()
    let catalog = try JSONDecoder().decode(TargetDiscovery.Catalog.self, from: catalogData)
    for target in catalog.allExecutionTargets {
      _ = try PrivateHeaderGeneration.ArtifactPath(target.artifactRoot)
    }
    return catalog
  }
}
