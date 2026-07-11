import Foundation
import Testing

@testable import PrivateHeaderKitCore

@Suite
struct PrivateHeaderGenerationArtifactPublisherTests {
  @Test func publishesImmutableGenerationThroughStableAndCurrentPointers() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-one")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "new"
    )

    #expect(try fixture.publisher.inspect().currentGenerationID == nil)
    try fixture.publisher.movePreparedGeneration(prepared)
    try fixture.publisher.switchCurrent(to: generationID)
    try fixture.publisher.ensureStablePointer()

    let snapshot = try fixture.publisher.inspect()
    #expect(snapshot.currentGenerationID == generationID)
    #expect(snapshot.stablePathState == .managed)
    #expect(
      snapshot.currentMarker?.artifactsByTarget["framework:Foo"]?.map(\.rawValue) == [
        "Frameworks/Foo/Foo.h"
      ])
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "new")
  }

  @Test func legacyFreshMigrationPreservesOpaqueContentAndRetainsOriginalTree() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let unknown = fixture.publisher.stableURL.appendingPathComponent("Notes/custom.txt")
    try FileManager.default.createDirectory(
      at: unknown.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("opaque".utf8).write(to: unknown)
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-legacy")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "header",
      allowLegacyMigration: true
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    try fixture.publisher.switchCurrent(to: generationID)
    try fixture.publisher.ensureStablePointer()

    #expect(try fixture.publisher.inspect().stablePathState == .managed)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Notes/custom.txt"),
        encoding: .utf8) == "opaque")
    let backups = try FileManager.default.contentsOfDirectory(
      at: fixture.publisher.managedRoot.appendingPathComponent("legacy-backups"),
      includingPropertiesForKeys: nil
    )
    #expect(backups.count == 1)
    #expect(
      try String(contentsOf: backups[0].appendingPathComponent("Notes/custom.txt"), encoding: .utf8)
        == "opaque")
  }

  @Test func unsuccessfulDraftNeverChangesCurrentGeneration() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let oldID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    try fixture.publish(
      fixture.prepare(
        generationID: oldID,
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "old"
      )
    )
    let draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-failed"),
      allowLegacyMigration: false
    )
    try fixture.publisher.discardDraft(draft)

    #expect(try fixture.publisher.inspect().currentGenerationID == oldID)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")
  }

  @Test func replacingOneOwnerPreservesOpaqueAndOtherTargetFiles() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let legacyUnknown = fixture.publisher.stableURL.appendingPathComponent("User/keep.txt")
    try FileManager.default.createDirectory(
      at: legacyUnknown.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: legacyUnknown)
    let first = try fixture.prepare(
      generationID: .init(rawValue: "generation-first"),
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Old.h",
      contents: "old",
      allowLegacyMigration: true
    )
    try fixture.publish(first)

    var draft = try fixture.publisher.beginDraft(
      generationID: .init(rawValue: "generation-second"),
      allowLegacyMigration: false
    )
    let barSource = try fixture.sourceFile(contents: "bar")
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Bar",
      files: [.init(rawValue: "Frameworks/Bar/Bar.h"): barSource],
      to: draft
    )
    let fooSource = try fixture.sourceFile(contents: "new")
    draft = try fixture.publisher.applyCompletedTarget(
      targetID: "framework:Foo",
      files: [.init(rawValue: "Frameworks/Foo/New.h"): fooSource],
      to: draft
    )
    try fixture.publish(
      try fixture.publisher.prepareGeneration(draft, planFingerprint: "fingerprint"))

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Old.h").path))
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Bar/Bar.h"),
        encoding: .utf8) == "bar")
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("User/keep.txt"),
        encoding: .utf8) == "keep")
  }

  @Test func rawStagingRejectsHiddenUnsupportedAndSymlinkPayloads() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let staging = fixture.root.appendingPathComponent("raw-staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    let header = staging.appendingPathComponent("Foo.h")
    try Data("header".utf8).write(to: header)
    try Data("hidden".utf8).write(to: staging.appendingPathComponent(".payload"))
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }

    try FileManager.default.removeItem(at: staging.appendingPathComponent(".payload"))
    try Data("bad".utf8).write(to: staging.appendingPathComponent("payload.txt"))
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }

    try FileManager.default.removeItem(at: staging.appendingPathComponent("payload.txt"))
    try FileManager.default.createSymbolicLink(
      at: staging.appendingPathComponent("Alias.h"),
      withDestinationURL: header
    )
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try fixture.publisher.validateRawStaging(root: staging, expectedSourceFiles: [header])
    }
  }

  @Test func managedDirectoryChainRejectsPreexistingSymlink() throws {
    let root = try publisherTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try publisherTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(".privateheaderkit"),
      withDestinationURL: outside
    )
    let publisher = try ArtifactPublisher(artifactBaseDirectory: root, sourceLabel: "iOS27")
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      try publisher.prepareForLease()
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func outputSymlinkAliasesShareCanonicalLeaseIdentity() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.deletingLastPathComponent().appendingPathComponent(
      "alias-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: alias) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let throughAlias = try ArtifactPublisher(artifactBaseDirectory: alias, sourceLabel: "iOS27")
    #expect(throughAlias.artifactBaseDirectory == fixture.publisher.artifactBaseDirectory)
    #expect(throughAlias.lockURL == fixture.publisher.lockURL)
  }

  @Test func reservedLegacyMarkerAndMalformedManagedGenerationFailFast() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(
      at: fixture.publisher.stableURL, withIntermediateDirectories: true)
    try Data("user".utf8).write(
      to: fixture.publisher.stableURL.appendingPathComponent(".privateheaderkit-generation.json")
    )
    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.beginDraft(
        generationID: .init(rawValue: "generation-reserved"),
        allowLegacyMigration: true
      )
    }
  }

  @Test func markerRejectsArtifactOwnedByMultipleTargets() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let generationID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-duplicate-owner")
    let prepared = try fixture.prepare(
      generationID: generationID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "header"
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    let markerURL = prepared.finalDirectory.appendingPathComponent(
      ".privateheaderkit-generation.json"
    )
    let data = try Data(contentsOf: markerURL)
    var marker = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var ownership = try #require(marker["artifactsByTarget"] as? [String: Any])
    ownership["framework:Bar"] = ["Frameworks/Foo/Foo.h"]
    marker["artifactsByTarget"] = ownership
    try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)

    #expect(throws: ArtifactPublisher.PublisherError.self) {
      _ = try fixture.publisher.inspect()
    }
  }

  @Test func stableReaderObservesOnlyCompleteOldOrNewGenerations() throws {
    let fixture = try PublisherFixture()
    defer { fixture.cleanup() }
    let oldID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-old")
    try fixture.publish(
      try fixture.prepare(
        generationID: oldID,
        targetID: "framework:Foo",
        relativePath: "Frameworks/Foo/Foo.h",
        contents: "old"
      ))
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")

    let newID = PrivateHeaderGeneration.GenerationID(rawValue: "generation-new")
    let prepared = try fixture.prepare(
      generationID: newID,
      targetID: "framework:Foo",
      relativePath: "Frameworks/Foo/Foo.h",
      contents: "new"
    )
    try fixture.publisher.movePreparedGeneration(prepared)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "old")
    try fixture.publisher.switchCurrent(to: newID)
    #expect(
      try String(
        contentsOf: fixture.publisher.stableURL.appendingPathComponent("Frameworks/Foo/Foo.h"),
        encoding: .utf8) == "new")
  }
}

private final class PublisherFixture {
  let root: URL
  let publisher: ArtifactPublisher

  init() throws {
    root = try publisherTemporaryDirectory()
    publisher = try ArtifactPublisher(artifactBaseDirectory: root, sourceLabel: "iOS27")
    try publisher.prepareForLease()
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }

  func sourceFile(contents: String) throws -> URL {
    let directory = root.appendingPathComponent("source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let url = directory.appendingPathComponent("artifact")
    try Data(contents.utf8).write(to: url)
    return url
  }

  func prepare(
    generationID: PrivateHeaderGeneration.GenerationID,
    targetID: String,
    relativePath: String,
    contents: String,
    allowLegacyMigration: Bool = false
  ) throws -> ArtifactPublisher.PreparedGeneration {
    var draft = try publisher.beginDraft(
      generationID: generationID,
      allowLegacyMigration: allowLegacyMigration
    )
    let source = try sourceFile(contents: contents)
    draft = try publisher.applyCompletedTarget(
      targetID: targetID,
      files: [try PrivateHeaderGeneration.ArtifactPath(relativePath): source],
      to: draft
    )
    return try publisher.prepareGeneration(draft, planFingerprint: "fingerprint")
  }

  func publish(_ prepared: ArtifactPublisher.PreparedGeneration) throws {
    try publisher.movePreparedGeneration(prepared)
    try publisher.switchCurrent(to: prepared.generationID)
    try publisher.ensureStablePointer()
  }
}

private func publisherTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "PrivateHeaderKitPublisherTests-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  return url
}
