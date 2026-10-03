import Foundation
import PrivateHeaderKitHelperProtocol

package extension PrivateHeaderKitOperatingSystemVersion {
  static func collect(systemRoot: URL = URL(fileURLWithPath: "/", isDirectory: true)) throws -> Self {
    struct SystemVersion: Decodable {
      let ProductVersion: String
      let ProductBuildVersion: String
    }
    struct RestoreVersion: Decodable { let IsSeed: Bool? }
    let decoder = PropertyListDecoder()
    let systemVersion = try decoder.decode(
      SystemVersion.self,
      from: Data(contentsOf: systemRoot.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
    )
    let restoreURL = systemRoot.appendingPathComponent("System/Library/CoreServices/RestoreVersion.plist")
    let metadataIsSeed: Bool
    do {
      metadataIsSeed = try decoder.decode(RestoreVersion.self, from: Data(contentsOf: restoreURL)).IsSeed ?? false
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      metadataIsSeed = false
    }
    return .init(version: systemVersion.ProductVersion, build: systemVersion.ProductBuildVersion, metadataIsSeed: metadataIsSeed)
  }
}
