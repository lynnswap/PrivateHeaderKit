import Foundation
import PrivateHeaderKitHelperProtocol
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationDeviceSourceTests {
  @Test func deviceSourceKeepsHeadersAndStateSeparateFromSimulatorSources() throws {
    let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let simulator = try PrivateHeaderGeneration.Source(
      platform: .iOS, version: "26.0.1", build: "23A355", metadataIsSeed: false
    )
    let device = try PrivateHeaderGeneration.Source(
      platform: .iOS, version: "26.0.1", build: "23A355", metadataIsSeed: false,
      imageVariant: .iPhoneOS(architecture: "cpu16777228-sub2", cacheUUID: cacheUUID)
    )
    let output = PrivateHeaderGeneration.Output(baseDirectory: URL(fileURLWithPath: "/tmp/Headers"))

    #expect(simulator.artifactPlatformDirectoryName == "iOS")
    #expect(device.artifactPlatformDirectoryName == "iPhoneOS")
    #expect(output.artifactDirectory(for: simulator).path == "/tmp/Headers/generated-headers/iOS/26.0.1_23A355")
    #expect(output.artifactDirectory(for: device).deletingLastPathComponent().lastPathComponent == "iPhoneOS")
    #expect(device.artifactDirectoryName.hasPrefix("26.0.1_23A355_"))
    #expect(device.artifactDirectoryName.hasSuffix(cacheUUID.uuidString.lowercased()))
    #expect(output.stateDirectory(for: device) != output.stateDirectory(for: simulator))
    #expect(device.storageIdentifier.contains("-iphoneos-"))
  }

  @Test func architectureAndCacheCohortEachSelectTheirOwnDeviceNamespace() throws {
    let firstUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let secondUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    func source(_ architecture: String, _ cacheUUID: UUID) throws -> PrivateHeaderGeneration.Source {
      try .init(
        platform: .iOS, version: "26.0.1", build: "23A355", metadataIsSeed: false,
        imageVariant: .iPhoneOS(architecture: architecture, cacheUUID: cacheUUID)
      )
    }
    let first = try source("cpu16777228-sub2", firstUUID)
    let differentArchitecture = try source("cpu16777228-sub0", firstUUID)
    let differentCache = try source("cpu16777228-sub2", secondUUID)

    #expect(Set([first.storageIdentifier, differentArchitecture.storageIdentifier, differentCache.storageIdentifier]).count == 3)
    #expect(Set([first.artifactDirectoryName, differentArchitecture.artifactDirectoryName, differentCache.artifactDirectoryName]).count == 3)
  }

  @Test func snapshotCollectsPeerMetadataAndTheExistingTargetCatalog() throws {
    let fixture = try DeviceSourceFixture(metadataIsSeed: true)
    defer { fixture.cleanup() }
    let snapshot = try fixture.snapshot()
    let roundTrip = try JSONDecoder().decode(
      PrivateHeaderGeneration.DeviceSourceSnapshot.self,
      from: JSONEncoder().encode(snapshot)
    )
    let source = try roundTrip.source()
    let catalog = try roundTrip.catalog()

    #expect(roundTrip == snapshot)
    #expect(roundTrip.version == "26.0.1")
    #expect(roundTrip.build == "23A355")
    #expect(roundTrip.producerVersion == PrivateHeaderKitBuildInfo.version)
    #expect(source.releaseChannel == .beta)
    #expect(source.imageVariant == .iPhoneOS(architecture: "cpu16777228-sub2", cacheUUID: fixture.cacheUUID))
    #expect(catalog.resolverCandidates.map(\.displayName) == ["SpringBoard", "libobjc.A.dylib"])
    #expect(catalog.allExecutionTargets.map(\.runtimeInputPath) == [
      "/System/Library/PrivateFrameworks/SpringBoard.framework", "/usr/lib/libobjc.A.dylib",
    ])
  }

  @Test func absentRestoreMetadataRepresentsAReleaseWhileMalformedMetadataFails() throws {
    let fixture = try DeviceSourceFixture(metadataIsSeed: nil)
    defer { fixture.cleanup() }
    #expect(try fixture.snapshot().source().releaseChannel == .release)

    try fixture.writePlist(["IsSeed": "true"], relativePath: "System/Library/CoreServices/RestoreVersion.plist")
    #expect(throws: DecodingError.self) { _ = try fixture.snapshot() }
  }

  @Test func physicalDeviceRestoreMetadataWithoutIsSeedRepresentsARelease() throws {
    let fixture = try DeviceSourceFixture(metadataIsSeed: nil)
    defer { fixture.cleanup() }
    try fixture.writePlist([
      "RestoreBuildGroup": "0",
      "RestoreLongVersion": "23.1.355.0.0,0",
      "RestoreVersion": "23.1.355.0.0",
    ], relativePath: "System/Library/CoreServices/RestoreVersion.plist")

    #expect(try fixture.snapshot().source().releaseChannel == .release)
  }

  @Test func sshFingerprintUsesTheSourceCohortAndOptionsInsteadOfTheConnectionAddress() throws {
    let fixture = try DeviceSourceFixture(metadataIsSeed: false)
    defer { fixture.cleanup() }
    let snapshot = try fixture.snapshot()
    let output = PrivateHeaderGeneration.Output(baseDirectory: fixture.root.appendingPathComponent("Output"))
    func fingerprint(destination: String, directory: String, controlPath: String, preferRuntimeMetadata: Bool = false) throws -> String {
      let mode = PrivateHeaderGeneration.RawDumping.ExecutionMode.ssh(destination: destination, directory: directory, controlPath: controlPath)
      let plan = PrivateHeaderGeneration.makePlan(
        source: try snapshot.source(), output: output,
        options: .init(
          systemRoot: URL(fileURLWithPath: "/"), executionMode: mode,
          rawDumpingOptions: .init(useSharedCache: true, preferRuntimeMetadata: preferRuntimeMetadata),
          deviceSource: snapshot
        )
      )
      return PrivateHeaderGeneration.GenerationExecutor.planFingerprint(
        plan, canonicalOutputBase: output.baseDirectory, executionMode: mode, sharedCacheCohort: nil
      )
    }
    let first = try fingerprint(destination: "se", directory: "/tmp/privateheaderkit-first", controlPath: "/tmp/phk-ssh-first/master")
    let reconnected = try fingerprint(destination: "ssh://mobile@127.0.0.1:2222", directory: "/tmp/privateheaderkit-second", controlPath: "/tmp/phk-ssh-second/master")
    let runtimeMetadata = try fingerprint(destination: "se", directory: "/tmp/privateheaderkit-third", controlPath: "/tmp/phk-ssh-third/master", preferRuntimeMetadata: true)

    #expect(first == reconnected)
    #expect(first != runtimeMetadata)
  }
}

private struct DeviceSourceFixture {
  let root: URL
  let cacheUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

  init(metadataIsSeed: Bool?) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceSourceTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writePlist(
      ["ProductVersion": "26.0.1", "ProductBuildVersion": "23A355"],
      relativePath: "System/Library/CoreServices/SystemVersion.plist"
    )
    if let metadataIsSeed {
      try writePlist(["IsSeed": metadataIsSeed], relativePath: "System/Library/CoreServices/RestoreVersion.plist")
    }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("System/Library/PrivateFrameworks/SpringBoard.framework"),
      withIntermediateDirectories: true
    )
    let objc = root.appendingPathComponent("usr/lib/libobjc.A.dylib")
    try FileManager.default.createDirectory(at: objc.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: objc)
  }

  func writePlist(_ value: [String: Any], relativePath: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
  }

  func snapshot() throws -> PrivateHeaderGeneration.DeviceSourceSnapshot {
    try .collect(
      systemRoot: root, architecture: "cpu16777228-sub2",
      inventory: .init(cacheUUID: cacheUUID, imagePaths: [
        "/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard",
        "/usr/lib/libobjc.A.dylib",
      ])
    )
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
