import CryptoKit
import Foundation
import PrivateHeaderKitHelperProtocol

extension PrivateHeaderGeneration {
  package struct ApplicationIdentity: Codable, Hashable, Sendable {
    package let bundleIdentifier: String
    package let version: String?
    package let build: String?
    package let executableUUID: UUID
    package let cpuType: Int32
    package let cpuSubtype: Int32

    package init(bundleIdentifier: String, version: String?, build: String?, image: PrivateHeaderKitProcessImage) throws {
      guard !bundleIdentifier.isEmpty, !bundleIdentifier.contains("\0") else {
        throw ValidationError.emptyComponent(field: "application bundle identifier")
      }
      self.bundleIdentifier = bundleIdentifier
      self.version = version
      self.build = build
      self.executableUUID = image.uuid
      self.cpuType = image.cpuType
      self.cpuSubtype = image.cpuSubtype
    }

    package var architecture: String { "cpu\(cpuType)-sub\(cpuSubtype)" }

    package var storageIdentifier: String {
      let fields = [bundleIdentifier, version, build, executableUUID.uuidString.lowercased(), architecture]
      let components = fields.flatMap { field in field.map { ["value", $0] } ?? ["none"] }
      let data = GenerationExecutor.canonicalFingerprintPayload(components)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
  }

  package struct ApplicationSourceSnapshot: Hashable, Sendable {
    package let identity: ApplicationIdentity
    package let recoveredBinaryPath: String
    package let localBinaryURL: URL?

    package init(identity: ApplicationIdentity, recoveredBinaryPath: String, localBinaryURL: URL? = nil) {
      self.identity = identity
      self.recoveredBinaryPath = recoveredBinaryPath
      self.localBinaryURL = localBinaryURL
    }

    package var logicalImagePath: String { "/Applications/" + identity.storageIdentifier + ".app/Executable" }

    func catalog() throws -> TargetDiscovery.Catalog {
      let candidate = try TargetCandidate(
        identifier: "application:" + identity.storageIdentifier,
        displayName: identity.bundleIdentifier,
        kind: .application
      )
      let target = TargetDiscovery.DiscoveredTarget(
        candidate: candidate,
        source: .application(logicalImagePath: logicalImagePath),
        artifactRoot: try ArtifactPath("Applications/" + identity.storageIdentifier + "/Headers"),
        inputPath: recoveredBinaryPath,
        runtimeInputPath: recoveredBinaryPath
      )
      return .init(groups: [.init(selectionCandidate: candidate, primaryTarget: target, childTargets: [])])
    }
  }
}
